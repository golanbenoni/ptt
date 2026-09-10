#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="$ROOT/deploy/media-node"

bash -n "$DEPLOY_DIR/install.sh" "$DEPLOY_DIR/renew-hook.sh" \
  "$ROOT/scripts/probe-livekit-cpu.sh"
"$ROOT/scripts/probe-livekit-cpu.sh" --self-test

if grep -Eq -- '-e LIVEKIT_(URL|API_KEY|API_SECRET)=' \
  "$ROOT/scripts/test-livekit-multiroom-load.sh"; then
  echo "The LiveKit load runner must not expose credentials in docker arguments" >&2
  exit 1
fi

for image in \
  'livekit/livekit-server:v1.13.6@sha256:' \
  'redis:7.4.6-alpine@sha256:' \
  'coturn/coturn:4.18.0-r0-alpine@sha256:' \
  'nginx:1.29.1-alpine@sha256:'; do
  grep -Fq "image: $image" "$DEPLOY_DIR/compose.yaml" || {
    echo "Missing digest-pinned media image: $image" >&2
    exit 1
  }
done

if grep -Eq 'image:[[:space:]]+[^[:space:]]+:latest([@[:space:]]|$)' \
  "$DEPLOY_DIR/compose.yaml"; then
  echo "The media deployment must not use latest-tag images" >&2
  exit 1
fi

for placeholder in CALLS_DOMAIN TURN_DOMAIN PUBLIC_IP PRIVATE_IP ADMIN_CIDR \
  LIVEKIT_API_KEY LIVEKIT_API_SECRET TURN_USERNAME TURN_PASSWORD \
  REDIS_PASSWORD METRICS_TOKEN; do
  if ! grep -qs "$placeholder" "$DEPLOY_DIR/install.sh" \
    "$DEPLOY_DIR"/*.template; then
    echo "The media deployment does not consume $placeholder" >&2
    exit 1
  fi
done

command -v docker >/dev/null || {
  echo "docker with the Compose plugin is required" >&2
  exit 1
}

work_dir="$(mktemp -d -t ptt-media-compose.XXXXXX)"
cleanup() {
  find "$work_dir" -depth -delete
}
trap cleanup EXIT INT TERM

cp "$DEPLOY_DIR/compose.yaml" "$work_dir/compose.yaml"
mkdir "$work_dir/runtime"
for runtime_file in redis-password livekit.yaml livekit-keys.yaml \
  turnserver.conf turn-fullchain.pem turn-privkey.pem nginx.conf; do
  : >"$work_dir/runtime/$runtime_file"
done
docker compose -f "$work_dir/compose.yaml" config --quiet

echo "Public media-node deployment contract passed"
