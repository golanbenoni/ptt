#!/usr/bin/env bash
# Drive encrypted calls in both Android<->iOS directions through one physical
# Android product path and one isolated iOS Simulator product instance. The iOS
# side deliberately uses muted simulator media, so this is interoperability and
# lifecycle evidence rather than CallKit, PushKit, routing, or acoustic proof.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_CALL_SERVER:?PTT_CALL_SERVER is required}"
: "${PTT_CALL_CONVERSATION_ID:?PTT_CALL_CONVERSATION_ID is required}"
: "${PTT_CALL_CALLER_ACI:?PTT_CALL_CALLER_ACI is required}"
: "${PTT_CALL_CALLER_MAILBOX:?PTT_CALL_CALLER_MAILBOX is required}"
: "${PTT_CALL_CALLER_TOKEN:?PTT_CALL_CALLER_TOKEN is required}"
: "${PTT_CALL_CALLER_IDENTITY_FIXTURE:?PTT_CALL_CALLER_IDENTITY_FIXTURE is required}"
: "${PTT_CALL_CALLEE_ACI:?PTT_CALL_CALLEE_ACI is required}"
: "${PTT_CALL_CALLEE_MAILBOX:?PTT_CALL_CALLEE_MAILBOX is required}"
: "${PTT_CALL_CALLEE_TOKEN:?PTT_CALL_CALLEE_TOKEN is required}"
: "${PTT_CALL_CALLEE_IDENTITY_FIXTURE:?PTT_CALL_CALLEE_IDENTITY_FIXTURE is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
APK="${PTT_ANDROID_AUTOMATION_APK:-$ROOT/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
ANDROID_PACKAGE="app.ptt.talk.debug"
ANDROID_ACTIVITY="$ANDROID_PACKAGE/app.ptt.talk.PhysicalE2EActivity"
IOS_APP="${PTT_IOS_CALL_APP:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
IOS_BUNDLE="app.ptt.talk"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"
SKIP_INSTALL="${PTT_ANDROID_SKIP_INSTALL:-0}"
WORK_DIR="$(mktemp -d -t ptt-cross-call.XXXXXX)"
IOS_SIM=""
IOS_CONTAINER=""
CALL_ID=""
CALL_END_TOKEN=""
REVERSED_PORTS=()

cleanup() {
  local exit_code=$?
  if [[ -n "$CALL_ID" && -n "$CALL_END_TOKEN" ]]; then
    curl -sS -H "Authorization: Bearer $CALL_END_TOKEN" -H 'Content-Type: application/json' \
      -d '{}' "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell am force-stop "$ANDROID_PACKAGE" >/dev/null 2>&1 || true
  for port in "${REVERSED_PORTS[@]}"; do
    "$ADB" -s "$PTT_ANDROID_DEVICE_1" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
  done
  if [[ -n "$IOS_SIM" ]]; then
    xcrun simctl shutdown "$IOS_SIM" >/dev/null 2>&1 || true
    xcrun simctl delete "$IOS_SIM" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_DIR"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

for command in curl jq openssl uuidgen xcrun ruby codesign; do
  command -v "$command" >/dev/null || { echo "Missing cross-platform call dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -d "$IOS_APP" || { echo "The signed iOS Simulator app is missing: $IOS_APP" >&2; exit 1; }
signature_details="$(codesign -dvv "$IOS_APP" 2>&1)"
if ! grep -Fq "Identifier=$IOS_BUNDLE" <<<"$signature_details" ||
   grep -Fq "linker-signed" <<<"$signature_details"; then
  echo "Cross-platform calls require a normally built iOS Simulator app with Keychain access." >&2
  exit 1
fi
[[ "$SKIP_INSTALL" == 0 || "$SKIP_INSTALL" == 1 ]] || { echo "PTT_ANDROID_SKIP_INSTALL must be 0 or 1." >&2; exit 1; }
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}
[[ "$PTT_CALL_SERVER" =~ ^http://(127\.0\.0\.1|localhost):([1-9][0-9]{1,4})$ ]] || {
  echo "The local cross-platform driver requires a loopback control origin." >&2
  exit 1
}
CONTROL_PORT="${BASH_REMATCH[2]}"
[[ "$($ADB -s "$PTT_ANDROID_DEVICE_1" get-state 2>/dev/null || true)" == device ]] || {
  echo "Android runtime $PTT_ANDROID_DEVICE_1 is unavailable or unauthorized." >&2
  exit 1
}

decode_fixture() {
  printf '%s' "$1" | openssl base64 -d -A -out "$2"
  jq -e '(.identityKeyPair | length) >= 80 and .registrationId >= 1 and .registrationId <= 16383' "$2" >/dev/null
}

copy_android_file() {
  local source="$1" name="$2" remote
  remote="/data/local/tmp/ptt-cross-$name-$(uuidgen)"
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" push "$source" "$remote" >/dev/null
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell run-as "$ANDROID_PACKAGE" mkdir -p files
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell run-as "$ANDROID_PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell rm "$remote"
}

read_android_marker() {
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" exec-out run-as "$ANDROID_PACKAGE" \
    cat "files/ptt-e2e-$1.txt" 2>/dev/null | tr -d '\r\n' || true
}

read_ios_marker() {
  local marker="$IOS_CONTAINER/Documents/ptt-e2e-$1.txt"
  [[ -f "$marker" ]] && tr -d '\r\n' <"$marker" || true
}

read_marker() {
  if [[ "$1" == android ]]; then read_android_marker "$2"; else read_ios_marker "$2"; fi
}

diagnostics() {
  if [[ "$1" == android ]]; then
    "$ADB" -s "$PTT_ANDROID_DEVICE_1" logcat -d -v brief 2>/dev/null |
      grep -E 'PTT_E2E|PTT_CALL|AndroidRuntime' | tail -120 |
      sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}/[redacted-uuid]/g' >&2 || true
  else
    xcrun simctl spawn "$IOS_SIM" log show --style compact --last 10m \
      --predicate 'process == "TalkApp" AND eventMessage CONTAINS "PTT_"' 2>/dev/null |
      tail -160 >&2 || true
  fi
}

wait_marker() {
  local platform="$1" name="$2" expected="$3" attempts="$4" value=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(read_marker "$platform" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "$platform marker $name did not reach $expected (last value: $value)." >&2
  diagnostics "$platform"
  return 1
}

prepare_android() {
  local mode="$1" role="$2" aci="$3" mailbox="$4" token="$5" fixture="$6"
  local peer="$7" call_id="${8:-}" preserve="${9:-true}" wait_prewarm="${10:-false}"
  local config="$WORK_DIR/android-config.json"
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell run-as "$ANDROID_PACKAGE" sh -c "'rm -f files/ptt-e2e-*.txt'" >/dev/null
  jq -cn --arg mode "$mode" --arg role "$role" --arg server "$PTT_CALL_SERVER" \
    --arg aci "$aci" --arg mailbox "$mailbox" --arg token "$token" \
    --arg channel "$PTT_CALL_CONVERSATION_ID" --arg peerAci "$peer" --arg callId "$call_id" \
    --arg run "$(uuidgen | tr '[:upper:]' '[:lower:]')" --argjson preserveState "$preserve" \
    --argjson waitForPrewarm "$wait_prewarm" \
    --argjson skipCryptoInitialization "$([[ "$mode" == call-prepare ]] && echo false || echo true)" \
    '{role:$role,mode:$mode,serverUrl:$server,aci:$aci,deviceId:1,mailboxId:$mailbox,
      accessToken:$token,channelId:$channel,run:$run,transmissions:1,peerAci:$peerAci,
      callId:$callId,preserveState:$preserveState,waitForPrewarm:$waitForPrewarm,
      skipCryptoInitialization:$skipCryptoInitialization}' >"$config"
  copy_android_file "$fixture" ptt-e2e-identity.json
  copy_android_file "$config" ptt-e2e-config.json
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell am force-stop "$ANDROID_PACKAGE"
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" logcat -c
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell am start -n "$ANDROID_ACTIVITY" >/dev/null
}

launch_ios() {
  local role="$1" aci="$2" mailbox="$3" token="$4" peer="$5" call_id="${6:-}"
  find "$IOS_CONTAINER/Documents" -maxdepth 1 -type f -name 'ptt-e2e-*.txt' -delete
  xcrun simctl terminate "$IOS_SIM" "$IOS_BUNDLE" >/dev/null 2>&1 || true
  local args=(--ptt-server "$PTT_CALL_SERVER" "--ptt-e2e-$role" --ptt-e2e-skip-voice
    "--ptt-e2e-call-$([[ "$role" == sender ]] && echo caller || echo callee)"
    --ptt-e2e-call-simulator-media-only)
  SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$token" SIMCTL_CHILD_PTT_E2E_ACI="$aci" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$mailbox" SIMCTL_CHILD_PTT_E2E_DEVICE=1 \
  SIMCTL_CHILD_PTT_CALL_PEER_ACI="$peer" SIMCTL_CHILD_PTT_CALL_ID="$call_id" \
    xcrun simctl launch "$IOS_SIM" "$IOS_BUNDLE" "${args[@]}" >/dev/null
}

wait_call_id() {
  local platform="$1" state=""
  CALL_ID=""
  for _ in {1..90}; do
    CALL_ID="$(read_marker "$platform" call-id)"
    [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && return 0
    state="$(read_marker "$platform" call-state)"
    [[ "$state" == fail:* ]] && break
    sleep 1
  done
  echo "$platform caller did not create a call (last state: $state)." >&2
  diagnostics "$platform"
  return 1
}

wait_android_service_release() {
  for _ in {1..30}; do
    if ! "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell dumpsys activity services "$ANDROID_PACKAGE" 2>/dev/null |
      grep -q CallSessionService; then return 0; fi
    sleep 1
  done
  echo "Android call service retained audio ownership after teardown." >&2
  diagnostics android
  return 1
}

verify_timings() {
  local label="$1" caller_platform="$2" callee_platform="$3"
  local created ringing answered caller_media callee_media invite_to_ring answer_to_media
  created="$(read_marker "$caller_platform" call-created-at-ms)"
  ringing="$(read_marker "$callee_platform" call-ringing-at-ms)"
  answered="$(read_marker "$callee_platform" call-answered-at-ms)"
  caller_media="$(read_marker "$caller_platform" call-media-connected-at-ms)"
  callee_media="$(read_marker "$callee_platform" call-media-connected-at-ms)"
  for value in "$created" "$ringing" "$answered" "$caller_media" "$callee_media"; do
    [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "$label is missing a timing marker." >&2; return 1; }
  done
  invite_to_ring=$((ringing - created))
  answer_to_media=$(( (caller_media > callee_media ? caller_media : callee_media) - answered ))
  (( invite_to_ring >= 0 && invite_to_ring <= MAX_INVITE_TO_RING_MS )) || {
    echo "$label invite-to-ring was ${invite_to_ring}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2; return 1;
  }
  (( answer_to_media >= 0 && answer_to_media <= MAX_ANSWER_TO_MEDIA_MS )) || {
    echo "$label answer-to-protected-media was ${answer_to_media}ms (limit ${MAX_ANSWER_TO_MEDIA_MS}ms)." >&2; return 1;
  }
  echo "$label passed (invite-to-ring ${invite_to_ring}ms, answer-to-protected-media ${answer_to_media}ms)."
}

end_call() {
  local token="$1"
  curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d '{}' "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
  for _ in {1..30}; do
    state="$(curl -fsS -H "Authorization: Bearer $token" "$PTT_CALL_SERVER/v1/calls/$CALL_ID" | jq -r .state)"
    [[ "$state" == ended ]] && break
    sleep 1
  done
  [[ "$state" == ended ]] || { echo "Cross-platform call did not end." >&2; return 1; }
  CALL_ID=""
  CALL_END_TOKEN=""
}

decode_fixture "$PTT_CALL_CALLER_IDENTITY_FIXTURE" "$WORK_DIR/ios-a.json"
decode_fixture "$PTT_CALL_CALLEE_IDENTITY_FIXTURE" "$WORK_DIR/android-b.json"
if [[ "$SKIP_INSTALL" == 0 ]]; then
  test -f "$APK" || { echo "Android debug APK is missing: $APK" >&2; exit 1; }
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" install -r -t "$APK" >/dev/null
else
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell pm path "$ANDROID_PACKAGE" >/dev/null
fi
"$ADB" -s "$PTT_ANDROID_DEVICE_1" shell pm grant "$ANDROID_PACKAGE" android.permission.RECORD_AUDIO >/dev/null
"$ADB" -s "$PTT_ANDROID_DEVICE_1" shell pm grant "$ANDROID_PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
IFS=',' read -r -a REVERSED_PORTS <<<"${PTT_CALL_REVERSE_PORTS:-$CONTROL_PORT,7880,7881}"
for port in "${REVERSED_PORTS[@]}"; do
  [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Invalid reverse port: $port" >&2; exit 1; }
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" reverse "tcp:$port" "tcp:$port" >/dev/null
done

runtime="$(xcrun simctl list runtimes --json | ruby -rjson -e '
  r = JSON.parse(STDIN.read).fetch("runtimes").select { |x| x["platform"] == "iOS" && x["isAvailable"] != false }
  puts r.max_by { |x| x.fetch("version", "0").split(".").map(&:to_i) }["identifier"]
')"
IOS_SIM="$(xcrun simctl create "PTT Android iOS call $$" \
  "${PTT_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}" "$runtime")"
xcrun simctl boot "$IOS_SIM"
xcrun simctl bootstatus "$IOS_SIM" -b >/dev/null
xcrun simctl install "$IOS_SIM" "$IOS_APP"
xcrun simctl privacy "$IOS_SIM" grant microphone "$IOS_BUNDLE"
IOS_CONTAINER="$(xcrun simctl get_app_container "$IOS_SIM" "$IOS_BUNDLE" data)"
mkdir -p "$IOS_CONTAINER/Documents"
cp "$WORK_DIR/ios-a.json" "$IOS_CONTAINER/Documents/ptt-e2e-identity.json"

# Prepare Android B before iOS A creates the first invitation so its prekeys are
# already authenticated and available to the iOS Double Ratchet sender.
prepare_android call-prepare receiver "$PTT_CALL_CALLEE_ACI" "$PTT_CALL_CALLEE_MAILBOX" \
  "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/android-b.json" "$PTT_CALL_CALLER_ACI" "" false false
wait_marker android receiver-state pass 120

echo "Running iOS-to-Android encrypted call"
launch_ios sender "$PTT_CALL_CALLER_ACI" "$PTT_CALL_CALLER_MAILBOX" \
  "$PTT_CALL_CALLER_TOKEN" "$PTT_CALL_CALLEE_ACI"
wait_call_id ios
CALL_END_TOKEN="$PTT_CALL_CALLER_TOKEN"
prepare_android call-callee receiver "$PTT_CALL_CALLEE_ACI" "$PTT_CALL_CALLEE_MAILBOX" \
  "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/android-b.json" "$PTT_CALL_CALLER_ACI" "$CALL_ID" true true
wait_marker ios call-state pass 150
wait_marker android call-state pass 150
verify_timings ios-to-android ios android
end_call "$PTT_CALL_CALLER_TOKEN"
wait_marker ios call-teardown pass 30
wait_android_service_release

echo "Running Android-to-iOS encrypted call"
prepare_android call-caller sender "$PTT_CALL_CALLEE_ACI" "$PTT_CALL_CALLEE_MAILBOX" \
  "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/android-b.json" "$PTT_CALL_CALLER_ACI" "" true false
wait_call_id android
CALL_END_TOKEN="$PTT_CALL_CALLEE_TOKEN"
launch_ios receiver "$PTT_CALL_CALLER_ACI" "$PTT_CALL_CALLER_MAILBOX" \
  "$PTT_CALL_CALLER_TOKEN" "$PTT_CALL_CALLEE_ACI" "$CALL_ID"
wait_marker android call-state pass 150
wait_marker ios call-state pass 150
verify_timings android-to-ios android ios
end_call "$PTT_CALL_CALLEE_TOKEN"
wait_marker ios call-teardown pass 30
wait_android_service_release

echo "Bidirectional Android/iOS encrypted call interoperability passed."
echo "The physical Android path was unmuted; the iOS Simulator path stayed muted by design, so this is not acoustic or CallKit evidence."
