#!/usr/bin/env bash
# Start disposable Rust/Postgres/Redis/object-store and pinned LiveKit services, load isolated test
# libsignal identities, then drive the production Android encrypted-call path on two runtimes.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"

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
if [[ ! -f "$LIBSIGNAL_ROOT/Cargo.toml" && -f "$HOME/src/libsignal-source/Cargo.toml" ]]; then
  LIBSIGNAL_ROOT="$HOME/src/libsignal-source"
fi
LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$LIBSIGNAL_ROOT/swift}"
LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$LIBSIGNAL_ROOT/target/debug}"
IOS_IDENTITY_APP="${PTT_IOS_IDENTITY_APP:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
IDENTITY_CACHE_DIR="${PTT_CALL_IDENTITY_CACHE_DIR:-$ROOT/.test-deps/call-identity-fixtures}"
REGENERATE_IDENTITIES="${PTT_CALL_REGENERATE_IDENTITIES:-0}"
CALL_DRIVER="${PTT_CALL_DRIVER:-$ROOT/scripts/test-android-two-device-calls.sh}"
WORK_DIR="$(mktemp -d -t ptt-android-call-stack.XXXXXX)"
READY_FILE="$WORK_DIR/control.ready"
CONTROL_LOG="$WORK_DIR/control-integration.log"
LIVEKIT_NAME="ptt-android-call-livekit-$$"
CONTROL_PID=""
IDENTITY_SIMS=()
IDENTITY_CACHE_HIT=0

cleanup() {
  local exit_code=$?
  unlink "$READY_FILE" 2>/dev/null || true
  if [[ -n "$CONTROL_PID" ]] && kill -0 "$CONTROL_PID" 2>/dev/null; then
    kill "$CONTROL_PID" 2>/dev/null || true
    wait "$CONTROL_PID" 2>/dev/null || true
  fi
  docker stop "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  docker rm "$LIVEKIT_NAME" >/dev/null 2>&1 || true
  for simulator in "${IDENTITY_SIMS[@]}"; do
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK_DIR"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

case "$LIVEKIT_IMAGE" in
  livekit/livekit-server:v1.13.6|livekit/livekit-server@sha256:*) ;;
  *) echo "Refusing unpinned LiveKit server image: $LIVEKIT_IMAGE" >&2; exit 1 ;;
esac
for command in docker jq openssl swift curl ruby; do
  command -v "$command" >/dev/null || { echo "Missing local call-gate dependency: $command" >&2; exit 1; }
done
EXPECTED_LIBSIGNAL_COMMIT=b056faa6dd02961cff24064c54c089c52e1a0753
[[ "$(git -C "$LIBSIGNAL_ROOT" rev-parse HEAD 2>/dev/null)" == "$EXPECTED_LIBSIGNAL_COMMIT" ]] || {
  echo "Identity generation requires pinned libsignal commit $EXPECTED_LIBSIGNAL_COMMIT." >&2
  exit 1
}
test -f "$LIBSIGNAL_SWIFT/Package.swift" || { echo "Pinned libsignal Swift package is missing." >&2; exit 1; }
for port in "$CONTROL_PORT" "$PUSH_PORT" "$GRPC_PORT" "$RELAY_PORT" "$METRICS_PORT" \
  "$LIVEKIT_HTTP_PORT" "$LIVEKIT_TCP_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Local call-gate port is invalid: $port" >&2; exit 1; }
done
[[ "$BUILD_APK" == 0 || "$BUILD_APK" == 1 ]] || {
  echo "PTT_ANDROID_CALL_BUILD_APK must be 0 or 1." >&2
  exit 1
}
[[ "$REGENERATE_IDENTITIES" == 0 || "$REGENERATE_IDENTITIES" == 1 ]] || {
  echo "PTT_CALL_REGENERATE_IDENTITIES must be 0 or 1." >&2
  exit 1
}
case "$CALL_DRIVER" in
  "$ROOT/scripts/test-android-two-device-calls.sh"|\
  "$ROOT/scripts/test-android-repeated-calls.sh"|\
  "$ROOT/scripts/test-android-two-device-call-acoustic.sh"|\
  "$ROOT/scripts/test-android-two-device-call-real-microphone.sh")
    : "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required for the two-Android driver}"
    ;;
  "$ROOT/scripts/test-android-ios-two-client-calls.sh") ;;
  *) echo "Unsupported local call driver: $CALL_DRIVER" >&2; exit 1 ;;
esac
test -x "$CALL_DRIVER" || { echo "Local call driver is not executable: $CALL_DRIVER" >&2; exit 1; }

if [[ "$BUILD_APK" == 1 ]]; then
  test -n "${JAVA_HOME:-}" || { echo "JAVA_HOME is required to build the Android automation app." >&2; exit 1; }
  test -n "${ANDROID_HOME:-}" || { echo "ANDROID_HOME is required to build the Android automation app." >&2; exit 1; }
  "$ROOT/gradlew" --quiet :talkandroid:assembleDebug
fi

mkdir -p "$WORK_DIR/identities" "$IDENTITY_CACHE_DIR"
chmod 700 "$IDENTITY_CACHE_DIR"
if [[ "$REGENERATE_IDENTITIES" == 0 &&
      -s "$IDENTITY_CACHE_DIR/sender.json" &&
      -s "$IDENTITY_CACHE_DIR/receiver.json" &&
      -s "$IDENTITY_CACHE_DIR/public.json" ]] &&
  jq -e '(.identityKeyPair | length) >= 80 and .registrationId >= 1 and .registrationId <= 16383' \
    "$IDENTITY_CACHE_DIR/sender.json" "$IDENTITY_CACHE_DIR/receiver.json" >/dev/null &&
  jq -e '(.senderIdentity | length) > 40 and (.receiverIdentity | length) > 40' \
    "$IDENTITY_CACHE_DIR/public.json" >/dev/null; then
  IDENTITY_CACHE_HIT=1
  cp "$IDENTITY_CACHE_DIR/sender.json" "$IDENTITY_CACHE_DIR/receiver.json" \
    "$IDENTITY_CACHE_DIR/public.json" "$WORK_DIR/identities/"
elif [[ -f "$LIBSIGNAL_FFI/libsignal_ffi.a" ]]; then
  : >"$WORK_DIR/identity-generation.log"
  if [[ ! -f "$ROOT/native/target/release/libptt_apple_ffi.a" ]] &&
    ! "$ROOT/scripts/build-apple-native.sh" >>"$WORK_DIR/identity-generation.log" 2>&1; then
    echo "Could not build the native Apple identity-generator dependency:" >&2
    tail -120 "$WORK_DIR/identity-generation.log" >&2
    exit 1
  fi
  if ! PTT_E2E_IDENTITY_EXPORT_DIR="$WORK_DIR/identities" \
    LIBSIGNAL_SWIFT="$LIBSIGNAL_SWIFT" LIBSIGNAL_FFI="$LIBSIGNAL_FFI" \
      swift run --package-path "$ROOT/ios/PttTalk" ProductionVoiceProbe generate-identity-fixtures \
      >>"$WORK_DIR/identity-generation.log" 2>&1; then
    echo "Could not generate fresh pinned libsignal identity fixtures:" >&2
    tail -120 "$WORK_DIR/identity-generation.log" >&2
    exit 1
  fi
else
  # Small-disk physical hosts may intentionally retain only the iOS-simulator
  # libsignal archive. Generate equivalent fixtures inside two isolated signed
  # simulator app containers instead of rebuilding the large macOS archive.
  command -v xcrun >/dev/null || { echo "No supported identity generator is available." >&2; exit 1; }
  test -d "$IOS_IDENTITY_APP" || { echo "Pinned libsignal macOS FFI and the iOS identity app are both missing." >&2; exit 1; }
  runtime="$(xcrun simctl list runtimes --json | ruby -rjson -e '
    r = JSON.parse(STDIN.read).fetch("runtimes").select { |x| x["platform"] == "iOS" && x["isAvailable"] != false }
      .max_by { |x| x.fetch("version", "0").split(".").map(&:to_i) }
    puts r["identifier"] if r
  ')"
  device_type="${PTT_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
  generate_simulator_identity() {
    local label="$1" destination="$2" simulator container
    simulator="$(xcrun simctl create "PTT Android identity $label $$" "$device_type" "$runtime")"
    IDENTITY_SIMS+=("$simulator")
    xcrun simctl boot "$simulator"
    xcrun simctl bootstatus "$simulator" -b >/dev/null
    xcrun simctl install "$simulator" "$IOS_IDENTITY_APP"
    xcrun simctl launch "$simulator" app.ptt.talk --ptt-generate-identity-fixture >/dev/null
    container="$(xcrun simctl get_app_container "$simulator" app.ptt.talk data)"
    for _ in {1..45}; do
      [[ -s "$container/Documents/generated-identity.json" &&
         -s "$container/Documents/generated-public-key.txt" ]] && break
      sleep 1
    done
    cp "$container/Documents/generated-identity.json" "$WORK_DIR/identities/$destination.json"
    tr -d '\r\n' <"$container/Documents/generated-public-key.txt" >"$WORK_DIR/identities/$label-public.txt"
    xcrun simctl shutdown "$simulator" >/dev/null
  }
  generate_simulator_identity sender sender
  generate_simulator_identity receiver receiver
  jq -n --rawfile senderIdentity "$WORK_DIR/identities/sender-public.txt" \
    --rawfile receiverIdentity "$WORK_DIR/identities/receiver-public.txt" \
    '{senderIdentity:$senderIdentity,receiverIdentity:$receiverIdentity}' \
    >"$WORK_DIR/identities/public.json"
fi
chmod 600 "$WORK_DIR/identities"/*.json
if [[ "$IDENTITY_CACHE_HIT" == 0 ]]; then
  for fixture in sender.json receiver.json public.json; do
    temporary="$IDENTITY_CACHE_DIR/$fixture.tmp.$$"
    cp "$WORK_DIR/identities/$fixture" "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$IDENTITY_CACHE_DIR/$fixture"
  done
fi
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
PTT_CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-15000}" \
PTT_CALL_INSPECTION_HOOK="$ROOT/scripts/assert-livekit-e2ee-room.sh" \
PTT_CALL_LIVEKIT_CONTAINER="$LIVEKIT_NAME" \
PTT_CALL_LIVEKIT_API_KEY=integration-call-key \
PTT_CALL_LIVEKIT_API_SECRET=integration-livekit-secret-at-least-32-bytes \
PTT_ANDROID_DEVICE_1="$PTT_ANDROID_DEVICE_1" PTT_ANDROID_DEVICE_2="${PTT_ANDROID_DEVICE_2:-}" \
  "$CALL_DRIVER"

unlink "$READY_FILE"
if ! wait "$CONTROL_PID"; then
  CONTROL_PID=""
  echo "The disposable Rust integration suite failed after the Android call completed:" >&2
  tail -120 "$CONTROL_LOG" >&2
  exit 1
fi
CONTROL_PID=""
echo "Disposable encrypted-call stack, selected mobile driver, and complete Rust integration suite passed."
