#!/usr/bin/env bash
# Prove that the SFU inspection hook fails closed when ordinary unencrypted
# LiveKit publishers appear in a call-shaped room.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_IMAGE="${PTT_LIVEKIT_SERVER_IMAGE:-livekit/livekit-server:v1.13.6}"
CLI_IMAGE="${PTT_LIVEKIT_CLI_IMAGE:-livekit/livekit-cli:v2.18.6}"
suffix="$$"
network="ptt-livekit-e2ee-inspection-$suffix"
server="ptt-android-call-livekit-$suffix"
client="ptt-livekit-e2ee-inspection-client-$suffix"
api_key=inspection-key
api_secret=inspection-secret-at-least-32-bytes

cleanup() {
  local exit_code=$?
  docker rm -f "$client" "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  return "$exit_code"
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
for command in docker grep; do
  command -v "$command" >/dev/null || {
    echo "Missing LiveKit inspection self-test dependency: $command" >&2
    exit 1
  }
done

docker network create "$network" >/dev/null
docker run -d --rm --name "$server" --network "$network" \
  "$SERVER_IMAGE" --dev --bind 0.0.0.0 --udp-port 7882 \
  --keys "$api_key: $api_secret" >/dev/null
ready=0
for _ in $(seq 1 45); do
  if docker run --rm --network "$network" \
    -e LIVEKIT_URL="http://$server:7880" -e LIVEKIT_API_KEY="$api_key" \
    -e LIVEKIT_API_SECRET="$api_secret" "$CLI_IMAGE" room list >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  echo "Pinned LiveKit node did not become ready for the E2EE inspection self-test." >&2
  exit 1
}

docker run -d --rm --name "$client" --network "$network" \
  -e LIVEKIT_URL="http://$server:7880" -e LIVEKIT_API_KEY="$api_key" \
  -e LIVEKIT_API_SECRET="$api_secret" "$CLI_IMAGE" perf load-test \
  --room inspection-room --duration 20s --audio-publishers 2 --subscribers 0 \
  --identity-prefix unencrypted --num-per-second 2 >/dev/null

output=""
if output="$(
  PTT_CALL_LIVEKIT_CONTAINER="$server" \
  PTT_CALL_LIVEKIT_API_KEY="$api_key" \
  PTT_CALL_LIVEKIT_API_SECRET="$api_secret" \
  PTT_CALL_REQUIRE_PSEUDONYMOUS_IDENTITIES=0 \
  PTT_LIVEKIT_CLI_IMAGE="$CLI_IMAGE" \
    "$ROOT/scripts/assert-livekit-e2ee-room.sh" 2>&1
)"; then
  echo "SFU inspection accepted unencrypted microphone publishers." >&2
  exit 1
fi
grep -Fq "without GCM E2EE" <<<"$output" || {
  echo "SFU inspection failed for an unexpected reason: $output" >&2
  exit 1
}

echo "SFU inspection self-test passed: unencrypted microphone publishers were rejected."
