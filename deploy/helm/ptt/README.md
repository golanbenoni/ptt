# PTT Talk on K3s

This chart is the supported self-hosted deployment target for production voice
v1. One Helm release is one private-team instance. It installs the control
service, web console, UDP relay, PostgreSQL, Redis, an S3-compatible encrypted
history store, object-store bucket initialization, and a coordinated backup
CronJob.

## Install

Create `operator-values.yaml` outside source control. Use independently random
values of at least 32 characters for every secret.

```yaml
publicBaseUrl: https://ptt.example.com
ingress:
  host: ptt.example.com
  tlsSecretName: ptt-tls
smtp:
  enabled: true
  host: smtp.example.com
  port: 587
  username: ptt@example.com
  from: PTT Talk <ptt@example.com>
secrets:
  databasePassword: replace-me
  redisPassword: replace-me
  objectStorePassword: replace-me
  sessionSigningKey: replace-me
  bootstrapToken: replace-me
  relaySharedSecret: replace-me
  smtpPassword: replace-me
```

Provision the named TLS secret with cert-manager or your operator certificate,
then install:

```sh
helm lint deploy/helm/ptt -f operator-values.yaml
helm upgrade --install ptt deploy/helm/ptt \
  --namespace ptt --create-namespace --wait --timeout 10m \
  -f operator-values.yaml
kubectl -n ptt rollout status deployment/ptt-ptt-control
kubectl -n ptt get pods,pvc,ingress
```

The bootstrap token is accepted only while no administrator exists. After the
first administrator enrolls, rotate that value so an old database snapshot
cannot make the original token useful again.

## Backup and restore

The daily CronJob stores a consistent PostgreSQL custom-format dump and a copy
of every ciphertext object under one UTC timestamp on the backup PVC. Redis is
ephemeral floor/presence state and is intentionally not restored. Trigger and
inspect a backup with:

```sh
kubectl -n ptt create job --from=cronjob/ptt-ptt-backup ptt-backup-manual
kubectl -n ptt wait --for=condition=complete job/ptt-backup-manual --timeout=20m
kubectl -n ptt logs job/ptt-backup-manual --all-containers
```

Before restoring, scale control and relay to zero and take a volume snapshot.
Attach the backup PVC to an operator-only temporary pod, select one timestamp,
run `pg_restore --clean --if-exists` against the PTT database, and mirror its
`objects/` directory back into the configured bucket. Restore both parts from
the same timestamp. Then scale services up and verify `/readyz`, administrator
login, device lists, and an encrypted history object before allowing traffic.

The chart deliberately does not automate a destructive restore. This prevents
an incorrect timestamp or namespace from silently replacing a live instance.

## Upgrade and rollback

Take and verify a manual backup first. Render and inspect the new manifests,
then use an atomic upgrade:

```sh
helm template ptt deploy/helm/ptt -n ptt -f operator-values.yaml > rendered.yaml
helm upgrade ptt deploy/helm/ptt -n ptt -f operator-values.yaml \
  --atomic --wait --timeout 10m
helm history ptt -n ptt
```

If application health fails and no irreversible migration has run, use
`helm rollback ptt REVISION -n ptt --wait`. If a migration is not backward
compatible, restore the pre-upgrade database and object snapshot together
before rolling the workloads back.
