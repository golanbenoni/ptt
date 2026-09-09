#!/usr/bin/env bash
# Exercise the pinned SFU with the v1 eight-party/two-speaker call shape.
# This is a deterministic transport smoke test, not the encrypted mobile or
# production-shaped performance release gate.
set -euo pipefail

SERVER_IMAGE="${PTT_LIVEKIT_SERVER_IMAGE:-livekit/livekit-server:v1.13.6}"
CLI_IMAGE="${PTT_LIVEKIT_CLI_IMAGE:-livekit/livekit-cli:v2.18.6}"
DURATION="${PTT_LIVEKIT_SMOKE_DURATION:-10s}"
suffix="$$"
network="ptt-livekit-smoke-$suffix"
server="ptt-livekit-smoke-server-$suffix"
room="ptt-eight-party-smoke-$suffix"
api_key="ptt-smoke"
api_secret="ptt-livekit-smoke-secret-at-least-32-bytes"

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

case "$SERVER_IMAGE" in
  livekit/livekit-server:v1.13.6|livekit/livekit-server@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit server image: $SERVER_IMAGE" >&2; exit 1 ;;
esac
case "$CLI_IMAGE" in
  livekit/livekit-cli:v2.18.6|livekit/livekit-cli@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit CLI image: $CLI_IMAGE" >&2; exit 1 ;;
esac
[[ "$DURATION" =~ ^[1-9][0-9]*s$ ]] || {
  echo "PTT_LIVEKIT_SMOKE_DURATION must be a positive whole number of seconds" >&2
  exit 1
}

docker network create "$network" >/dev/null
docker run -d --rm --name "$server" --network "$network" \
  "$SERVER_IMAGE" --dev --bind 0.0.0.0 --udp-port 7882 \
  --keys "$api_key: $api_secret" >/dev/null

ready=0
for _ in $(seq 1 45); do
  if docker run --rm --network "$network" \
    -e LIVEKIT_URL="http://$server:7880" \
    -e LIVEKIT_API_KEY="$api_key" -e LIVEKIT_API_SECRET="$api_secret" \
    "$CLI_IMAGE" room list >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  docker logs --tail 80 "$server" >&2 || true
  echo "Pinned LiveKit node did not become ready" >&2
  exit 1
fi

server_version="$(docker exec "$server" /livekit-server --version 2>/dev/null || true)"
[[ "$server_version" == *"1.13.6"* ]] || {
  echo "Unexpected LiveKit server version: $server_version" >&2
  exit 1
}

result="$(docker run --rm --network "$network" \
  -e LIVEKIT_URL="http://$server:7880" \
  -e LIVEKIT_API_KEY="$api_key" -e LIVEKIT_API_SECRET="$api_secret" \
  "$CLI_IMAGE" perf load-test --room "$room" --duration "$DURATION" \
  --audio-publishers 2 --subscribers 6 --num-per-second 8 --simulate-speakers 2>&1)"

total_line="$(grep '│ Total ' <<<"$result" | tail -n 1 || true)"
if [[ "$total_line" != *"12/12"* || "$total_line" != *"0 (0%)"* || "$total_line" != *"│ 0     │"* ]]; then
  printf '%s\n' "$result" >&2
  echo "Eight-party SFU smoke did not deliver both audio tracks to all six subscribers" >&2
  exit 1
fi

echo "Pinned LiveKit 1.13.6 carried two simultaneous audio publishers to six subscribers with all 12 subscriptions healthy."
