# PTT Talk on K3s

This chart is the supported self-hosted deployment target for PTT Talk 0.1.21
(24), protocol 1.1. One Helm release is one private-team instance. It installs the control
service, web console, UDP relay, PostgreSQL, Redis, an S3-compatible encrypted
history store, object-store bucket initialization, and a coordinated backup
CronJob.

The chart and core service APIs include the mobile-approved administrator
browser flow: a two-minute single-use handoff becomes a 15-minute revocable
browser-only session. Do not copy a permanent device credential into the
browser. Remaining operational release gates are tracked in
[`../../../docs/CURRENT_STATE.md`](../../../docs/CURRENT_STATE.md).

## Install

Prerequisites are a K3s host, Helm 3, a DNS name, a certificate covering both
HTTP and gRPC hosts, an SMTP sender, an encrypted persistent storage class,
Firebase server credentials, and two independent app-topic-restricted APNs
keys. A development install may omit delivery providers, but store/physical
release gates fail closed without them.

Create `operator-values.yaml` outside source control. Use independently random
values of at least 32 characters for every secret.

```yaml
publicBaseUrl: https://ptt.example.com
ingress:
  host: ptt.example.com
  grpcHost: grpc.ptt.example.com
  tlsSecretName: ptt-tls
smtp:
  enabled: true
  host: smtp.example.com
  port: 587
  username: ptt@example.com
  from: PTT Talk <ptt@example.com>
push:
  fcm:
    enabled: true
  apns:
    enabled: true
    productionKeyId: ABC123DEFG
    sandboxKeyId: KLM123NOPQ
    teamId: DEF123GHIJ
    bundleId: app.ptt.talk
secrets:
  databasePassword: replace-with-a-random-database-password
  redisPassword: replace-with-a-random-redis-password
  objectStorePassword: replace-with-a-random-object-store-password
  bootstrapToken: replace-with-at-least-32-random-characters
  relaySharedSecret: replace-with-at-least-32-random-characters
  metricsToken: replace-with-at-least-32-random-characters
  smtpPassword: replace-with-your-smtp-password
  fcmServiceAccountJson: '{"type":"service_account", ...}'
  apnsProductionPrivateKey: |-
    -----BEGIN PRIVATE KEY-----
    replace-me
    -----END PRIVATE KEY-----
  apnsSandboxPrivateKey: |-
    -----BEGIN PRIVATE KEY-----
    replace-me
    -----END PRIVATE KEY-----
```

Generate unique values for every placeholder; do not install the literal
examples. Bootstrap, relay, and metrics secrets must each contain at least 32
characters, and the chart rejects shorter values before deployment. Production
and sandbox APNs key IDs and private keys must also be independent; the chart
rejects reused credentials.

Provision the named TLS secret with cert-manager or your operator certificate;
the certificate must cover both `ingress.host` and `ingress.grpcHost`. The
separate gRPC hostname terminates public TLS at Traefik and uses h2c only on the
cluster-local hop to the control pod. Then install:

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

## Abuse controls

The supported K3s/Traefik path installs a source-address rate-limit middleware
for REST/WebSocket and gRPC ingress. Tune `ingress.rateLimit.average`, `burst`,
and `period` for the deployment, or disable it only when an equivalent upstream
control is verified. Magic-link and recovery requests also have a privacy-keyed
application limit of five requests per address per hour; Redis keys contain
only truncated SHA-256 digests, never email addresses.

## Metrics and alerts

The control pod exposes Prometheus text format on the cluster-only `metrics`
service port. `/metrics` requires `Authorization: Bearer <metricsToken>` and
emits aggregate gauges without account, device, email, channel, token, key, or
media labels. It is deliberately absent from public ingress.

For an installed Prometheus Operator, enable the provided scrape and alert
rules:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    interval: 30s
  prometheusRule:
    enabled: true
    pendingPushThreshold: 100
    failedPushThreshold: 0
```

The default rules detect a push backlog, repeated push failures, and database
connection pressure. Rotate `secrets.metricsToken` with other operator secrets.

## Backup and restore

The daily CronJob stores a consistent PostgreSQL custom-format dump and a copy
of every ciphertext object under one UTC timestamp on the backup PVC. Backups
are disabled by default so the chart cannot silently write account records to
an unencrypted K3s `local-path` volume. Provision a storage class that provides
encryption at rest, verify its key ownership and recovery procedure, and then
set all three values explicitly:

```yaml
backup:
  enabled: true
  storageClassName: operator-encrypted
  encryptedStorageClassConfirmed: true
```

Helm refuses to render an enabled backup until that confirmation is present.
The confirmation is an operator assertion, not an encryption mechanism; its
storage class must actually encrypt the backing volume. Redis is ephemeral
floor/presence state and is intentionally not restored. Trigger and inspect a
configured backup with:

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

The repository does automate this procedure in a disposable test cluster. The
gate builds the control, relay, and administrator images from the checkout,
installs a fresh two-node K3s cluster, writes database and ciphertext-object
markers, backs them up, deletes them, restores both parts, and checks service
recovery:

```sh
./scripts/test-k3s-clean-install.sh
```

It also performs an upgrade and rollback before deleting the cluster. Its
explicit test-only confirmation for K3s `local-path` storage is not evidence of
encryption at rest and must never be copied into production values.

The Postgres, Redis, MinIO, MinIO client, and backup finalizer defaults are
pinned to multi-architecture image digests. Set `control.image.digest`,
`relay.image.digest`, and `adminWeb.image.digest` to the signed CI-produced
digests in production rather than relying on their mutable tags.

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
