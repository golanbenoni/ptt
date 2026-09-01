#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/deploy/helm/ptt"
BASE=(
  --set secrets.databasePassword=test-only
  --set secrets.redisPassword=test-only
  --set secrets.objectStorePassword=test-only
  --set secrets.bootstrapToken=test-only-32-byte-bootstrap-token
  --set secrets.relaySharedSecret=test-only-32-byte-relay-shared-key
  --set secrets.metricsToken=test-only-32-byte-metrics-access-key
  --set push.apns.enabled=true
  --set push.apns.teamId=M2M4752Z6K
  --set push.apns.bundleId=app.ptt.talk
)

helm template ptt "$CHART" "${BASE[@]}" \
  --set push.apns.productionKeyId=ABCDEFGHIJ \
  --set push.apns.sandboxKeyId=KLMNOPQRST \
  --set secrets.apnsProductionPrivateKey=production-private-key \
  --set secrets.apnsSandboxPrivateKey=sandbox-private-key >/dev/null

if helm template ptt "$CHART" "${BASE[@]}" \
  --set push.apns.productionKeyId=ABCDEFGHIJ \
  --set push.apns.sandboxKeyId=ABCDEFGHIJ \
  --set secrets.apnsProductionPrivateKey=reused-private-key \
  --set secrets.apnsSandboxPrivateKey=reused-private-key >/dev/null 2>&1; then
  echo "Helm accepted reused production and sandbox APNs credentials." >&2
  exit 1
fi

echo "Helm APNs credential separation gate passed"
