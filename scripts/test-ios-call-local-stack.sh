#!/usr/bin/env bash
# Start a disposable Rust control plane and pinned LiveKit node, generate two
# fresh iOS libsignal identities, and drive the product's iOS call path through
# two isolated simulators.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Reserve a distinct set while selecting defaults. The sockets close when Ruby
# exits, immediately before this single-host test starts binding them. Dynamic
# defaults keep a canceled test's orphaned process/container from poisoning a
# later release run; explicit ports remain available for local diagnostics.
IFS=' ' read -r AUTO_CONTROL_PORT AUTO_PUSH_PORT AUTO_GRPC_PORT AUTO_RELAY_PORT \
  AUTO_METRICS_PORT AUTO_LIVEKIT_HTTP_PORT AUTO_LIVEKIT_TCP_PORT < <(
  ruby -rsocket -e '
    tcp = 6.times.map { TCPServer.new("127.0.0.1", 0) }
    udp = UDPSocket.new
    udp.bind("127.0.0.1", 0)
    ports = [tcp[0].addr[1], tcp[1].addr[1], tcp[2].addr[1], udp.addr[1],
             tcp[3].addr[1], tcp[4].addr[1], tcp[5].addr[1]]
    puts ports.join(" ")
  '
)
CONTROL_PORT="${PTT_CALL_LOCAL_CONTROL_PORT:-$AUTO_CONTROL_PORT}"
PUSH_PORT="${PTT_CALL_LOCAL_PUSH_PORT:-$AUTO_PUSH_PORT}"
GRPC_PORT="${PTT_CALL_LOCAL_GRPC_PORT:-$AUTO_GRPC_PORT}"
RELAY_PORT="${PTT_CALL_LOCAL_RELAY_PORT:-$AUTO_RELAY_PORT}"
METRICS_PORT="${PTT_CALL_LOCAL_METRICS_PORT:-$AUTO_METRICS_PORT}"
LIVEKIT_HTTP_PORT="${PTT_CALL_LOCAL_LIVEKIT_HTTP_PORT:-$AUTO_LIVEKIT_HTTP_PORT}"
LIVEKIT_TCP_PORT="${PTT_CALL_LOCAL_LIVEKIT_TCP_PORT:-$AUTO_LIVEKIT_TCP_PORT}"
LIVEKIT_CONTAINER_HTTP_PORT=7880
LIVEKIT_CONTAINER_TCP_PORT=7881
LIVEKIT_IMAGE="${PTT_LIVEKIT_SERVER_IMAGE:-livekit/livekit-server:v1.13.6}"
APP_PATH="${PTT_IOS_CALL_APP:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
WORK_DIR="$(mktemp -d -t ptt-ios-call-stack.XXXXXX)"
READY_FILE="$WORK_DIR/control.ready"
CONTROL_LOG="$WORK_DIR/control-integration.log"
LIVEKIT_NAME="ptt-ios-call-livekit-$$"
CONTROL_PID=""
GENERATOR_SIMS=()

cleanup() {
  local exit_code=$?
  unlink "$READY_FILE" 2>/dev/null || true
  if [[ -n "$CONTROL_PID" ]] && kill -0 "$CONTROL_PID" 2>/dev/null; then
    kill "$CONTROL_PID" 2>/dev/null || true
    wait "$CONTROL_PID" 2>/dev/null || true
  fi
  docker stop "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  docker rm "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  if ((${#GENERATOR_SIMS[@]})); then
    for simulator in "${GENERATOR_SIMS[@]}"; do
      xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
      xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    done
  fi
  rm -rf -- "$WORK_DIR"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

case "$LIVEKIT_IMAGE" in
  livekit/livekit-server:v1.13.6|livekit/livekit-server@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit server image: $LIVEKIT_IMAGE" >&2; exit 1 ;;
esac
for command in docker jq openssl curl ruby xcrun; do
  command -v "$command" >/dev/null || { echo "Missing local iOS call-gate dependency: $command" >&2; exit 1; }
done
test -d "$APP_PATH" || { echo "Built iOS simulator app is missing: $APP_PATH" >&2; exit 1; }
for port in "$CONTROL_PORT" "$PUSH_PORT" "$GRPC_PORT" "$RELAY_PORT" "$METRICS_PORT" \
  "$LIVEKIT_HTTP_PORT" "$LIVEKIT_TCP_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Local iOS call-gate port is invalid: $port" >&2; exit 1; }
done

runtime="$(xcrun simctl list runtimes --json | ruby -rjson -e '
  runtimes = JSON.parse(STDIN.read).fetch("runtimes").select do |item|
    item["platform"] == "iOS" && item["isAvailable"] != false
  end
  selected = runtimes.max_by { |item| item.fetch("version", "0").split(".").map(&:to_i) }
  puts selected["identifier"] if selected
')"
device_type="${PTT_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
[[ -n "$runtime" ]] || { echo "No available iOS Simulator runtime was found." >&2; exit 1; }

generate_identity() {
  local label="$1" output="$2"
  local simulator container
  simulator="$(xcrun simctl create "PTT Call identity $label $$" "$device_type" "$runtime")"
  GENERATOR_SIMS+=("$simulator")
  xcrun simctl boot "$simulator"
  xcrun simctl bootstatus "$simulator" -b >/dev/null
  xcrun simctl install "$simulator" "$APP_PATH"
  xcrun simctl launch "$simulator" app.ptt.talk --ptt-generate-identity-fixture >/dev/null
  container="$(xcrun simctl get_app_container "$simulator" app.ptt.talk data)"
  for _ in {1..45}; do
    [[ -s "$container/Documents/generated-identity.json" &&
       -s "$container/Documents/generated-public-key.txt" ]] && break
    sleep 1
  done
  test -s "$container/Documents/generated-identity.json"
  test -s "$container/Documents/generated-public-key.txt"
  cp "$container/Documents/generated-identity.json" "$output-identity.json"
  cp "$container/Documents/generated-public-key.txt" "$output-public.txt"
  xcrun simctl shutdown "$simulator" >/dev/null
}

generate_identity caller "$WORK_DIR/caller"
generate_identity callee "$WORK_DIR/callee"
CALLER_IDENTITY="$(openssl base64 -A -in "$WORK_DIR/caller-identity.json")"
CALLEE_IDENTITY="$(openssl base64 -A -in "$WORK_DIR/callee-identity.json")"
PUBLIC_IDENTITY_A="$(tr -d '\r\n' <"$WORK_DIR/caller-public.txt")"
PUBLIC_IDENTITY_B="$(tr -d '\r\n' <"$WORK_DIR/callee-public.txt")"

docker run -d --name "$LIVEKIT_NAME" \
  -p "127.0.0.1:$LIVEKIT_HTTP_PORT:$LIVEKIT_CONTAINER_HTTP_PORT" \
  -p "127.0.0.1:$LIVEKIT_TCP_PORT:$LIVEKIT_CONTAINER_TCP_PORT" \
  "$LIVEKIT_IMAGE" --node-ip 127.0.0.1 --config-body "$(printf '%s\n' \
    "port: $LIVEKIT_CONTAINER_HTTP_PORT" \
    "rtc:" \
    "  tcp_port: $LIVEKIT_CONTAINER_TCP_PORT" \
    "keys:" \
    "  integration-call-key: integration-livekit-secret-at-least-32-bytes" \
    "webhook:" \
    "  api_key: integration-call-key" \
    "  urls:" \
    "    - http://host.docker.internal:$CONTROL_PORT/v1/internal/livekit/webhook")" >/dev/null
for _ in $(seq 1 45); do
  curl -fsS "http://127.0.0.1:$LIVEKIT_HTTP_PORT" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$LIVEKIT_HTTP_PORT" >/dev/null

PTT_INTEGRATION_PORT="$CONTROL_PORT" PTT_PUSH_MOCK_PORT="$PUSH_PORT" \
PTT_GRPC_INTEGRATION_PORT="$GRPC_PORT" PTT_RELAY_INTEGRATION_PORT="$RELAY_PORT" \
PTT_METRICS_INTEGRATION_PORT="$METRICS_PORT" \
PTT_INTEGRATION_PUBLIC_BASE_URL="http://127.0.0.1:$CONTROL_PORT" \
PTT_INTEGRATION_LIVEKIT_URL="ws://127.0.0.1:$LIVEKIT_HTTP_PORT" \
PTT_INTEGRATION_LIVEKIT_API_KEY=integration-call-key \
PTT_INTEGRATION_LIVEKIT_API_SECRET=integration-livekit-secret-at-least-32-bytes \
PTT_INTEGRATION_IDENTITY_A="$PUBLIC_IDENTITY_A" PTT_INTEGRATION_IDENTITY_B="$PUBLIC_IDENTITY_B" \
PTT_INTEGRATION_READY_FILE="$READY_FILE" "$ROOT/scripts/test-control-integration.sh" \
  >"$CONTROL_LOG" 2>&1 &
CONTROL_PID=$!
for _ in $(seq 1 120); do
  [[ -e "$READY_FILE" ]] && break
  if ! kill -0 "$CONTROL_PID" 2>/dev/null; then
    tail -80 "$CONTROL_LOG" >&2
    exit 1
  fi
  sleep 1
done
[[ -e "$READY_FILE" ]] || { echo "Disposable iOS call control stack did not become ready." >&2; exit 1; }

PTT_CALL_SERVER="http://127.0.0.1:$CONTROL_PORT" \
PTT_CALL_CONVERSATION_ID=49999999-9999-4999-8999-999999999999 \
PTT_CALL_CALLER_ACI=66666666-6666-4666-8666-666666666666 \
PTT_CALL_CALLER_MAILBOX=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee \
PTT_CALL_CALLER_TOKEN=integration-call-device-a PTT_CALL_CALLER_IDENTITY_FIXTURE="$CALLER_IDENTITY" \
PTT_CALL_CALLEE_ACI=88888888-8888-4888-8888-888888888888 \
PTT_CALL_CALLEE_MAILBOX=ffffffff-ffff-4fff-8fff-ffffffffffff \
PTT_CALL_CALLEE_TOKEN=integration-call-device-b PTT_CALL_CALLEE_IDENTITY_FIXTURE="$CALLEE_IDENTITY" \
  "$ROOT/scripts/test-ios-two-simulator-calls.sh"

unlink "$READY_FILE"
if ! wait "$CONTROL_PID"; then
  CONTROL_PID=""
  echo "The disposable Rust suite failed after the iOS call completed:" >&2
  tail -120 "$CONTROL_LOG" >&2
  exit 1
fi
CONTROL_PID=""
echo "Disposable iOS encrypted-call stack and complete Rust integration suite passed."
