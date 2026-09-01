#!/bin/sh
set -eu

for command_name in curl docker helm jq k3d kubectl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required for the K3s clean-install gate" >&2
    exit 1
  }
done

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ptt-k3s-gate.XXXXXX")
cluster_name="ptt-k3s-gate-$$"
image_tag="k3s-gate-$$"
namespace=ptt-gate
control_port=${PTT_K3S_CONTROL_PORT:-28080}
admin_port=${PTT_K3S_ADMIN_PORT:-28081}
metrics_port=${PTT_K3S_METRICS_PORT:-29090}
port_forward_pids=""

cleanup() {
  status=$?
  trap - EXIT INT TERM

  for pid in $port_forward_pids; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done

  if [ "$status" -ne 0 ] && k3d cluster list -o json 2>/dev/null | jq -e --arg name "$cluster_name" '.[] | select(.name == $name)' >/dev/null; then
    kubectl -n "$namespace" get pods,pvc,services,events -o wide >"$work_dir/cluster-state.log" 2>&1 || true
    kubectl -n "$namespace" logs -l app.kubernetes.io/instance=ptt --all-containers --prefix --tail=200 >"$work_dir/pod-logs.log" 2>&1 || true
    echo "K3s gate diagnostics: $work_dir" >&2
  fi

  k3d cluster delete "$cluster_name" >/dev/null 2>&1 || true
  docker image rm "ptt-control:$image_tag" "ptt-relay:$image_tag" "ptt-admin-web:$image_tag" >/dev/null 2>&1 || true

  if [ "$status" -eq 0 ]; then
    rm -rf "$work_dir"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

export KUBECONFIG="$work_dir/kubeconfig"

docker info >/dev/null
docker build -f "$repo_root/server/control/Dockerfile" -t "ptt-control:$image_tag" "$repo_root"
docker build -f "$repo_root/server/relay/Dockerfile" -t "ptt-relay:$image_tag" "$repo_root"
docker build -f "$repo_root/admin-web/Dockerfile" -t "ptt-admin-web:$image_tag" "$repo_root"

k3d cluster create "$cluster_name" --agents 1 --wait --timeout 180s
k3d image import -c "$cluster_name" \
  "ptt-control:$image_tag" \
  "ptt-relay:$image_tag" \
  "ptt-admin-web:$image_tag"

helm install ptt "$repo_root/deploy/helm/ptt" \
  --namespace "$namespace" --create-namespace --wait --timeout 10m \
  --set ingress.enabled=false \
  --set relay.service.type=ClusterIP \
  --set control.image.repository=ptt-control \
  --set "control.image.tag=$image_tag" \
  --set control.image.pullPolicy=Never \
  --set relay.image.repository=ptt-relay \
  --set "relay.image.tag=$image_tag" \
  --set relay.image.pullPolicy=Never \
  --set adminWeb.image.repository=ptt-admin-web \
  --set "adminWeb.image.tag=$image_tag" \
  --set adminWeb.image.pullPolicy=Never \
  --set postgres.storage=1Gi \
  --set redis.storage=256Mi \
  --set objectStore.storage=1Gi \
  --set backup.enabled=true \
  --set backup.storage=1Gi \
  --set backup.storageClassName=local-path \
  --set backup.encryptedStorageClassConfirmed=true \
  --set secrets.databasePassword=test-only-database-password \
  --set secrets.redisPassword=test-only-redis-password \
  --set secrets.objectStorePassword=test-only-object-password \
  --set secrets.bootstrapToken=test-only-32-byte-bootstrap-token \
  --set secrets.relaySharedSecret=test-only-32-byte-relay-shared-key \
  --set secrets.metricsToken=test-only-32-byte-metrics-access-key

kubectl -n "$namespace" rollout status deployment/ptt-ptt-admin-web --timeout=180s
kubectl -n "$namespace" rollout status deployment/ptt-ptt-control --timeout=180s
kubectl -n "$namespace" rollout status deployment/ptt-ptt-relay --timeout=180s
kubectl -n "$namespace" rollout status statefulset/ptt-ptt-object-store --timeout=180s
kubectl -n "$namespace" rollout status statefulset/ptt-ptt-postgres --timeout=180s
kubectl -n "$namespace" rollout status statefulset/ptt-ptt-redis --timeout=180s
test "$(kubectl -n "$namespace" get pods -l app.kubernetes.io/instance=ptt -o json | jq '[.items[] | select(.status.phase == "Running")] | length')" -eq 6

kubectl -n "$namespace" port-forward service/ptt-ptt-control \
  "$control_port:8080" "$metrics_port:9090" >"$work_dir/control-port-forward.log" 2>&1 &
port_forward_pids="$port_forward_pids $!"
kubectl -n "$namespace" port-forward service/ptt-ptt-admin-web \
  "$admin_port:8080" >"$work_dir/admin-port-forward.log" 2>&1 &
port_forward_pids="$port_forward_pids $!"

attempt=0
until curl -fsS "http://localhost:$control_port/readyz" 2>/dev/null | jq -e '.status == "ready"' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 60 || {
    echo "control readiness endpoint did not become ready" >&2
    exit 1
  }
  sleep 1
done

curl -fsS "http://localhost:$control_port/healthz" | jq -e '.status == "ok"' >/dev/null
test "$(curl -fsS "http://localhost:$admin_port/healthz")" = "ok"
curl -fsS -D "$work_dir/admin-headers" "http://localhost:$admin_port/admin/" -o "$work_dir/admin-index"
grep -qi '^Content-Security-Policy:' "$work_dir/admin-headers"
test -s "$work_dir/admin-index"

unauthorized_metrics=$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$metrics_port/metrics")
test "$unauthorized_metrics" = 401
metrics_token=$(kubectl -n "$namespace" get secret ptt-ptt -o jsonpath='{.data.metrics-token}' | base64 --decode)
curl -fsS -H "Authorization: Bearer $metrics_token" "http://localhost:$metrics_port/metrics" | grep -q '^ptt_database_connections '

tables=$(kubectl -n "$namespace" exec ptt-ptt-postgres-0 -- psql -U ptt -d ptt -Atc \
  "SELECT to_regclass('public.admin_console_handoffs'), to_regclass('public.admin_console_sessions');")
test "$tables" = "admin_console_handoffs|admin_console_sessions"

for pid in $port_forward_pids; do
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
done
port_forward_pids=""

kubectl -n "$namespace" exec ptt-ptt-postgres-0 -- psql -U ptt -d ptt -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE restore_probe (value text PRIMARY KEY); INSERT INTO restore_probe VALUES ('database-restore-proof');" >/dev/null

object_client_image=$(kubectl -n "$namespace" get cronjob ptt-ptt-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.initContainers[1].image}')
postgres_image=$(kubectl -n "$namespace" get statefulset ptt-ptt-postgres \
  -o jsonpath='{.spec.template.spec.containers[0].image}')

kubectl -n "$namespace" run ptt-object-write \
  --restart=Never \
  --image="$object_client_image" \
  --labels=app.kubernetes.io/name=ptt,app.kubernetes.io/instance=ptt,app.kubernetes.io/component=backup \
  --env=MC_CONFIG_DIR=/tmp/.mc \
  --env=MINIO_ROOT_PASSWORD=test-only-object-password \
  --command -- /bin/sh -ec \
  "until mc alias set ptt http://ptt-ptt-object-store:9000 ptt \"\$MINIO_ROOT_PASSWORD\"; do sleep 2; done; printf restore-proof | mc pipe ptt/ptt-history/operations/restore-proof.txt"
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ptt-object-write --timeout=120s
kubectl -n "$namespace" delete pod ptt-object-write --wait=true >/dev/null

kubectl -n "$namespace" create job --from=cronjob/ptt-ptt-backup ptt-backup-manual
kubectl -n "$namespace" wait --for=condition=complete job/ptt-backup-manual --timeout=300s
kubectl -n "$namespace" logs job/ptt-backup-manual --all-containers --prefix >"$work_dir/backup.log"

kubectl -n "$namespace" scale deployment/ptt-ptt-control deployment/ptt-ptt-relay --replicas=0
kubectl -n "$namespace" wait --for=delete pod -l app.kubernetes.io/component=control --timeout=120s
kubectl -n "$namespace" wait --for=delete pod -l app.kubernetes.io/component=relay --timeout=120s
kubectl -n "$namespace" exec ptt-ptt-postgres-0 -- psql -U ptt -d ptt -v ON_ERROR_STOP=1 -c \
  "DROP TABLE restore_probe;" >/dev/null

kubectl -n "$namespace" run ptt-object-delete \
  --restart=Never \
  --image="$object_client_image" \
  --labels=app.kubernetes.io/name=ptt,app.kubernetes.io/instance=ptt,app.kubernetes.io/component=backup \
  --env=MC_CONFIG_DIR=/tmp/.mc \
  --env=MINIO_ROOT_PASSWORD=test-only-object-password \
  --command -- /bin/sh -ec \
  "until mc alias set ptt http://ptt-ptt-object-store:9000 ptt \"\$MINIO_ROOT_PASSWORD\"; do sleep 2; done; mc rm ptt/ptt-history/operations/restore-proof.txt"
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ptt-object-delete --timeout=120s
kubectl -n "$namespace" delete pod ptt-object-delete --wait=true >/dev/null

cat <<EOF | kubectl -n "$namespace" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ptt-postgres-restore
  labels:
    app.kubernetes.io/name: ptt
    app.kubernetes.io/instance: ptt
    app.kubernetes.io/component: backup
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: restore
      image: "$postgres_image"
      command: ["/bin/sh", "-ec"]
      args:
        - |
          BACKUP_DIR=
          for candidate in /backups/*; do
            if [ -d "\$candidate" ]; then
              BACKUP_DIR="\$candidate"
            fi
          done
          test -n "\$BACKUP_DIR"
          attempt=0
          until pg_restore --clean --if-exists --no-owner --dbname="\$DATABASE_URL" "\$BACKUP_DIR/postgres.dump"; do
            attempt=\$((attempt + 1))
            test "\$attempt" -lt 60
            sleep 2
          done
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: ptt-ptt
              key: database-url
        - name: PGCONNECT_TIMEOUT
          value: "5"
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
      volumeMounts:
        - name: backup
          mountPath: /backups
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ptt-ptt-backup
    - name: tmp
      emptyDir: {}
EOF
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ptt-postgres-restore --timeout=300s

cat <<EOF | kubectl -n "$namespace" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ptt-object-restore
  labels:
    app.kubernetes.io/name: ptt
    app.kubernetes.io/instance: ptt
    app.kubernetes.io/component: backup
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: restore
      image: "$object_client_image"
      command: ["/bin/sh", "-ec"]
      args:
        - |
          BACKUP_DIR=
          for candidate in /backups/*; do
            if [ -d "\$candidate" ]; then
              BACKUP_DIR="\$candidate"
            fi
          done
          test -n "\$BACKUP_DIR"
          until mc alias set ptt http://ptt-ptt-object-store:9000 ptt "\$MINIO_ROOT_PASSWORD"; do
            sleep 2
          done
          mc mirror --overwrite "\$BACKUP_DIR/objects" ptt/ptt-history
          test "\$(mc cat ptt/ptt-history/operations/restore-proof.txt)" = restore-proof
      env:
        - name: MC_CONFIG_DIR
          value: /tmp/.mc
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ptt-ptt
              key: object-store-password
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
      volumeMounts:
        - name: backup
          mountPath: /backups
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: backup
      persistentVolumeClaim:
        claimName: ptt-ptt-backup
    - name: tmp
      emptyDir: {}
EOF
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ptt-object-restore --timeout=300s

test "$(kubectl -n "$namespace" exec ptt-ptt-postgres-0 -- psql -U ptt -d ptt -Atc 'SELECT value FROM restore_probe;')" = database-restore-proof
kubectl -n "$namespace" delete pod ptt-postgres-restore ptt-object-restore --wait=true >/dev/null

kubectl -n "$namespace" scale deployment/ptt-ptt-control deployment/ptt-ptt-relay --replicas=1
kubectl -n "$namespace" rollout status deployment/ptt-ptt-control --timeout=180s
kubectl -n "$namespace" rollout status deployment/ptt-ptt-relay --timeout=180s

helm upgrade ptt "$repo_root/deploy/helm/ptt" --namespace "$namespace" --reuse-values \
  --set publicBaseUrl=https://upgrade-gate.invalid --wait --timeout 10m
test "$(kubectl -n "$namespace" get deployment ptt-ptt-control -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "PTT_PUBLIC_BASE_URL").value')" = https://upgrade-gate.invalid
helm rollback ptt 1 --namespace "$namespace" --wait --timeout 10m
test "$(kubectl -n "$namespace" get deployment ptt-ptt-control -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "PTT_PUBLIC_BASE_URL").value')" = https://ptt.example.com

for node in "k3d-$cluster_name-agent-0" "k3d-$cluster_name-server-0"; do
  started_before=$(docker inspect -f '{{.State.StartedAt}}' "$node")
  docker restart "$node" >/dev/null
  started_after=$(docker inspect -f '{{.State.StartedAt}}' "$node")
  test "$started_before" != "$started_after"

  attempt=0
  until kubectl get node "$node" -o json 2>/dev/null | \
    jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 120 || {
      echo "K3s node $node did not recover after restart" >&2
      exit 1
    }
    sleep 1
  done

  kubectl -n "$namespace" rollout status deployment/ptt-ptt-admin-web --timeout=300s
  kubectl -n "$namespace" rollout status deployment/ptt-ptt-control --timeout=300s
  kubectl -n "$namespace" rollout status deployment/ptt-ptt-relay --timeout=300s
  kubectl -n "$namespace" rollout status statefulset/ptt-ptt-object-store --timeout=300s
  kubectl -n "$namespace" rollout status statefulset/ptt-ptt-postgres --timeout=300s
  kubectl -n "$namespace" rollout status statefulset/ptt-ptt-redis --timeout=300s
done

test "$(kubectl -n "$namespace" exec ptt-ptt-postgres-0 -- psql -U ptt -d ptt -Atc 'SELECT value FROM restore_probe;')" = database-restore-proof
kubectl -n "$namespace" run ptt-object-restart-read \
  --restart=Never \
  --image="$object_client_image" \
  --labels=app.kubernetes.io/name=ptt,app.kubernetes.io/instance=ptt,app.kubernetes.io/component=backup \
  --env=MC_CONFIG_DIR=/tmp/.mc \
  --env=MINIO_ROOT_PASSWORD=test-only-object-password \
  --command -- /bin/sh -ec \
  "until mc alias set ptt http://ptt-ptt-object-store:9000 ptt \"\$MINIO_ROOT_PASSWORD\"; do sleep 2; done; test \"\$(mc cat ptt/ptt-history/operations/restore-proof.txt)\" = restore-proof"
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/ptt-object-restart-read --timeout=120s
kubectl -n "$namespace" delete pod ptt-object-restart-read --wait=true >/dev/null

kubectl -n "$namespace" port-forward service/ptt-ptt-control \
  "$control_port:8080" >"$work_dir/final-control-port-forward.log" 2>&1 &
port_forward_pids="$port_forward_pids $!"
attempt=0
until curl -fsS "http://localhost:$control_port/readyz" 2>/dev/null | jq -e '.status == "ready"' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 60 || {
    echo "restored control service did not become ready" >&2
    exit 1
  }
  sleep 1
done

echo "K3s clean-install gate passed for chart $(helm show chart "$repo_root/deploy/helm/ptt" | awk '/^version:/ {print $2}')"
