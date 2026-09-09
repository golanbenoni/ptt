#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template ptt "$repo_root/deploy/helm/ptt" \
  --set calls.enabled=true \
  --set publicBaseUrl=https://ptt.example.com \
  --set calls.domain=calls.ptt.example.com \
  --set calls.turnDomain=turn.ptt.example.com \
  --set livekit.livekit.turn.domain=turn.ptt.example.com \
  --set secrets.databasePassword=test-database-password \
  --set secrets.redisPassword=test-redis-password \
  --set livekit.livekit.redis.password=test-redis-password \
  --set secrets.objectStorePassword=test-object-password \
  --set secrets.bootstrapToken=test-only-32-byte-bootstrap-token \
  --set secrets.relaySharedSecret=test-only-32-byte-relay-shared-key \
  --set secrets.metricsToken=test-only-32-byte-metrics-access-key \
  --set secrets.livekitApiKey=ptt-call-v1 \
  --set secrets.livekitApiSecret=test-only-32-byte-livekit-secret-key \
  > "$rendered"

grep -q 'image: "livekit/livekit-server:v1.13.6"' "$rendered"
grep -q 'name: LIVEKIT_CONFIG' "$rendered"
grep -A5 'name: LIVEKIT_CONFIG' "$rendered" | grep -q 'secretKeyRef:'
if grep -B2 -A4 'config.yaml: |' "$rendered" | grep -q 'kind: ConfigMap'; then
  echo "LiveKit configuration containing Redis credentials was rendered as a ConfigMap" >&2
  exit 1
fi
grep -q 'hostNetwork: true' "$rendered"
grep -q 'name: turn-tls' "$rendered"
grep -q 'name: turn-udp' "$rendered"
grep -q 'name: rtc-udp' "$rendered"
for forbidden in livekit-egress livekit-ingress livekit-sip livekit-agent; do
  if grep -qi "$forbidden" "$rendered"; then
    echo "Forbidden optional LiveKit component rendered: $forbidden" >&2
    exit 1
  fi
done

echo "Pinned encrypted-call Helm contract passed."
