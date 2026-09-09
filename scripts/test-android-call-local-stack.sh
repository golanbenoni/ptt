#!/usr/bin/env bash
# Start disposable Rust/Postgres/Redis/object-store and pinned LiveKit services, generate two fresh
# libsignal identities, then drive the production Android encrypted-call path on two runtimes.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTROL_PORT="${PTT_CALL_LOCAL_CONTROL_PORT:-32183}"
PUSH_PORT="${PTT_CALL_LOCAL_PUSH_PORT:-32184}"
GRPC_PORT="${PTT_CALL_LOCAL_GRPC_PORT:-32185}"
RELAY_PORT="${PTT_CALL_LOCAL_RELAY_PORT:-32186}"
METRICS_PORT="${PTT_CALL_LOCAL_METRICS_PORT:-32187}"
LIVEKIT_HTTP_PORT="${PTT_CALL_LOCAL_LIVEKIT_HTTP_PORT:-7880}"
LIVEKIT_TCP_PORT="${PTT_CALL_LOCAL_LIVEKIT_TCP_PORT:-7881}"
LIVEKIT_IMAGE="${PTT_LIVEKIT_SERVER_IMAGE:-livekit/livekit-server:v1.13.6}"
BUILD_APK="${PTT_ANDROID_CALL_BUILD_APK:-1}"
LIBSIGNAL_ROOT="${LIBSIGNAL_ROOT:-$ROOT/libsignal}"
LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$LIBSIGNAL_ROOT/swift}"
LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$LIBSIGNAL_ROOT/target/debug}"
WORK_DIR="$(mktemp -d -t ptt-android-call-stack.XXXXXX)"
READY_FILE="$WORK_DIR/control.ready"
CONTROL_LOG="$WORK_DIR/control-integration.log"
LIVEKIT_NAME="ptt-android-call-livekit-$$"
CONTROL_PID=""

cleanup() {
  local exit_code=$?
  unlink "$READY_FILE" 2>/dev/null || true
  if [[ -n "$CONTROL_PID" ]] && kill -0 "$CONTROL_PID" 2>/dev/null; then
    kill "$CONTROL_PID" 2>/dev/null || true
    wait "$CONTROL_PID" 2>/dev/null || true
  fi
  docker stop "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  docker rm "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

case "$LIVEKIT_IMAGE" in
  livekit/livekit-server:v1.13.6|livekit/livekit-server@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit server image: $LIVEKIT_IMAGE" >&2; exit 1 ;;
esac
for command in docker jq openssl swift curl; do
  command -v "$command" >/dev/null || { echo "Missing local call-gate dependency: $command" >&2; exit 1; }
done
test -f "$LIBSIGNAL_SWIFT/Package.swift" || { echo "Pinned libsignal Swift package is missing." >&2; exit 1; }
test -f "$LIBSIGNAL_FFI/libsignal_ffi.a" || { echo "Pinned libsignal macOS FFI library is missing." >&2; exit 1; }
for port in "$CONTROL_PORT" "$PUSH_PORT" "$GRPC_PORT" "$RELAY_PORT" "$METRICS_PORT" \
  "$LIVEKIT_HTTP_PORT" "$LIVEKIT_TCP_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Local call-gate port is invalid: $port" >&2; exit 1; }
done
[[ "$BUILD_APK" == 0 || "$BUILD_APK" == 1 ]] || {
  echo "PTT_ANDROID_CALL_BUILD_APK must be 0 or 1." >&2
  exit 1
}

if [[ "$BUILD_APK" == 1 ]]; then
  test -n "${JAVA_HOME:-}" || { echo "JAVA_HOME is required to build the Android automation app." >&2; exit 1; }
  test -n "${ANDROID_HOME:-}" || { echo "ANDROID_HOME is required to build the Android automation app." >&2; exit 1; }
  "$ROOT/gradlew" --quiet :talkandroid:assembleDebug
fi

mkdir -p "$WORK_DIR/identities"
PTT_E2E_IDENTITY_EXPORT_DIR="$WORK_DIR/identities" \
LIBSIGNAL_SWIFT="$LIBSIGNAL_SWIFT" LIBSIGNAL_FFI="$LIBSIGNAL_FFI" \
  swift run --package-path "$ROOT/ios/PttTalk" ProductionVoiceProbe generate-identity-fixtures \
  >"$WORK_DIR/identity-generation.log" 2>&1
chmod 600 "$WORK_DIR/identities"/*.json
CALLER_IDENTITY="$(openssl base64 -A -in "$WORK_DIR/identities/sender.json")"
CALLEE_IDENTITY="$(openssl base64 -A -in "$WORK_DIR/identities/receiver.json")"
PUBLIC_IDENTITY_A="$(jq -er .senderIdentity "$WORK_DIR/identities/public.json")"
PUBLIC_IDENTITY_B="$(jq -er .receiverIdentity "$WORK_DIR/identities/public.json")"

docker run -d --name "$LIVEKIT_NAME" \
  -p "127.0.0.1:$LIVEKIT_HTTP_PORT:$LIVEKIT_HTTP_PORT" \
  -p "127.0.0.1:$LIVEKIT_TCP_PORT:$LIVEKIT_TCP_PORT" \
  "$LIVEKIT_IMAGE" --node-ip 127.0.0.1 --config-body "$(printf '%s\n' \
    "port: $LIVEKIT_HTTP_PORT" \
    "rtc:" \
    "  tcp_port: $LIVEKIT_TCP_PORT" \
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
  if [[ -e "$READY_FILE" ]]; then break; fi
  if ! kill -0 "$CONTROL_PID" 2>/dev/null; then
    tail -80 "$CONTROL_LOG" >&2
    exit 1
  fi
  sleep 1
done
[[ -e "$READY_FILE" ]] || { echo "Disposable call control stack did not become ready." >&2; exit 1; }

PTT_CALL_SERVER="http://127.0.0.1:$CONTROL_PORT" \
PTT_CALL_CONVERSATION_ID=49999999-9999-4999-8999-999999999999 \
PTT_CALL_CALLER_ACI=66666666-6666-4666-8666-666666666666 \
PTT_CALL_CALLER_MAILBOX=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee \
PTT_CALL_CALLER_TOKEN=integration-call-device-a PTT_CALL_CALLER_IDENTITY_FIXTURE="$CALLER_IDENTITY" \
PTT_CALL_CALLEE_ACI=88888888-8888-4888-8888-888888888888 \
PTT_CALL_CALLEE_MAILBOX=ffffffff-ffff-4fff-8fff-ffffffffffff \
PTT_CALL_CALLEE_TOKEN=integration-call-device-b PTT_CALL_CALLEE_IDENTITY_FIXTURE="$CALLEE_IDENTITY" \
PTT_CALL_REVERSE_PORTS="$CONTROL_PORT,$LIVEKIT_HTTP_PORT,$LIVEKIT_TCP_PORT" \
PTT_ANDROID_DEVICE_1="$PTT_ANDROID_DEVICE_1" PTT_ANDROID_DEVICE_2="$PTT_ANDROID_DEVICE_2" \
  "$ROOT/scripts/test-android-two-device-calls.sh"

unlink "$READY_FILE"
if ! wait "$CONTROL_PID"; then
  CONTROL_PID=""
  echo "The disposable Rust integration suite failed after the Android call completed:" >&2
  tail -120 "$CONTROL_LOG" >&2
  exit 1
fi
CONTROL_PID=""
echo "Disposable Android encrypted-call stack and its complete Rust integration suite passed."
