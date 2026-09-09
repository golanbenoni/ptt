#!/usr/bin/env bash
# Prove one encrypted full-duplex call direction between a physical Android
# device and a physical Apple device. Both apps must already be installed from
# the exact checkout under test.
set -euo pipefail

: "${PTT_CALL_DIRECTION:?PTT_CALL_DIRECTION must be android-to-ios or ios-to-android}"
: "${PTT_ANDROID_DEVICE:?PTT_ANDROID_DEVICE is required}"
: "${PTT_IOS_DEVICE:?PTT_IOS_DEVICE is required}"
: "${PTT_CALL_SERVER:?PTT_CALL_SERVER is required}"
: "${PTT_CALL_CONVERSATION_ID:?PTT_CALL_CONVERSATION_ID is required}"
: "${PTT_ANDROID_ACI:?PTT_ANDROID_ACI is required}"
: "${PTT_ANDROID_DEVICE_ID:?PTT_ANDROID_DEVICE_ID is required}"
: "${PTT_ANDROID_MAILBOX:?PTT_ANDROID_MAILBOX is required}"
: "${PTT_ANDROID_TOKEN:?PTT_ANDROID_TOKEN is required}"
: "${PTT_ANDROID_IDENTITY_FIXTURE:?PTT_ANDROID_IDENTITY_FIXTURE is required}"
: "${PTT_IOS_ACI:?PTT_IOS_ACI is required}"
: "${PTT_IOS_DEVICE_ID:?PTT_IOS_DEVICE_ID is required}"
: "${PTT_IOS_MAILBOX:?PTT_IOS_MAILBOX is required}"
: "${PTT_IOS_TOKEN:?PTT_IOS_TOKEN is required}"
: "${PTT_IOS_IDENTITY_FIXTURE:?PTT_IOS_IDENTITY_FIXTURE is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
ANDROID_PACKAGE="${PTT_ANDROID_AUTOMATION_PACKAGE:-app.ptt.talk.debug}"
ANDROID_ACTIVITY="$ANDROID_PACKAGE/app.ptt.talk.PhysicalE2EActivity"
IOS_BUNDLE="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
DEVICE_TIMEOUT="${PTT_IOS_DEVICE_COMMAND_TIMEOUT_SECONDS:-12}"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"
DIAGNOSTIC_AUDIO="${PTT_CALL_DIAGNOSTIC_AUDIO:-0}"
REQUIRE_REAL_MIC_AUDIO="${PTT_CALL_REQUIRE_REAL_MIC_AUDIO:-0}"
FORCE_ANDROID_SPEAKER="${PTT_CALL_FORCE_SPEAKER:-0}"
MUTE_CALLEE_DURING_HOOK="${PTT_CALL_MUTE_CALLEE_DURING_HOOK:-$REQUIRE_REAL_MIC_AUDIO}"
ATTENUATE_ANDROID_CALLEE_OUTPUT="${PTT_CALL_ATTENUATE_CALLEE_OUTPUT_DURING_HOOK:-$REQUIRE_REAL_MIC_AUDIO}"
CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-5000}"
ACTIVE_HOOK="${PTT_CALL_ACTIVE_HOOK:-}"
WORK_DIR="$(mktemp -d -t ptt-physical-cross-call.XXXXXX)"
CALL_ID=""
CALLER_TOKEN=""
IOS_CONSOLE=""
IOS_CONSOLE_PID=""
ANDROID_OUTPUT_ORIGINAL_VOLUME=""

restore_android_output_volume() {
  if [[ "$ANDROID_OUTPUT_ORIGINAL_VOLUME" =~ ^[0-9]+$ ]]; then
    local expected_volume="$ANDROID_OUTPUT_ORIGINAL_VOLUME" restored_volume=""
    "$ADB" -s "$PTT_ANDROID_DEVICE" shell cmd media_session volume \
      --stream 0 --set "$expected_volume" >/dev/null 2>&1 || return 1
    restored_volume="$(
      "$ADB" -s "$PTT_ANDROID_DEVICE" shell cmd media_session volume --stream 0 --get 2>/dev/null |
        sed -nE 's/.*volume is ([0-9]+) in range.*/\1/p' | tail -1
    )"
    [[ "$restored_volume" == "$expected_volume" ]] || return 1
    ANDROID_OUTPUT_ORIGINAL_VOLUME=""
  fi
}

cleanup() {
  local exit_code=$?
  restore_android_output_volume || true
  if [[ -n "$CALL_ID" && -n "$CALLER_TOKEN" ]]; then
    curl -sS -H "Authorization: Bearer $CALLER_TOKEN" -H 'Content-Type: application/json' \
      -d '{}' "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell am force-stop "$ANDROID_PACKAGE" >/dev/null 2>&1 || true
  "$ROOT/scripts/terminate-ios-talk-app.sh" "$PTT_IOS_DEVICE" >/dev/null 2>&1 || true
  if [[ "$IOS_CONSOLE_PID" =~ ^[0-9]+$ ]]; then
    kill -TERM "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
  fi
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
  return "$exit_code"
}
trap cleanup EXIT INT TERM

for command in curl jq node openssl ruby uuidgen xcrun; do
  command -v "$command" >/dev/null || { echo "Missing physical cross-call dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
[[ "$PTT_CALL_DIRECTION" == android-to-ios || "$PTT_CALL_DIRECTION" == ios-to-android ]] || {
  echo "PTT_CALL_DIRECTION must be android-to-ios or ios-to-android." >&2
  exit 1
}
[[ "$PTT_CALL_SERVER" == https://* ]] || { echo "Physical cross-platform calls require HTTPS." >&2; exit 1; }
[[ "$PTT_ANDROID_DEVICE_ID" =~ ^[12]$ && "$PTT_IOS_DEVICE_ID" =~ ^[12]$ ]] || {
  echo "Physical call device IDs must be 1 or 2." >&2
  exit 1
}
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}
[[ "$DIAGNOSTIC_AUDIO" =~ ^[01]$ && "$REQUIRE_REAL_MIC_AUDIO" =~ ^[01]$ &&
   "$FORCE_ANDROID_SPEAKER" =~ ^[01]$ && "$MUTE_CALLEE_DURING_HOOK" =~ ^[01]$ &&
   "$ATTENUATE_ANDROID_CALLEE_OUTPUT" =~ ^[01]$ ]] || {
  echo "Physical call diagnostic flags must be 0 or 1." >&2
  exit 1
}
if [[ ! "$CALL_PROOF_DURATION_MS" =~ ^[0-9]+$ ]] ||
  (( CALL_PROOF_DURATION_MS < 5000 || CALL_PROOF_DURATION_MS > 20000 )); then
  echo "PTT_CALL_PROOF_DURATION_MS must be between 5000 and 20000." >&2
  exit 1
fi
if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  [[ "$DIAGNOSTIC_AUDIO" == 1 ]] || {
    echo "Real-microphone proof requires PTT_CALL_DIAGNOSTIC_AUDIO=1." >&2
    exit 1
  }
  [[ -n "$ACTIVE_HOOK" && -x "$ACTIVE_HOOK" ]] || {
    echo "Real-microphone proof requires an executable PTT_CALL_ACTIVE_HOOK." >&2
    exit 1
  }
  (( CALL_PROOF_DURATION_MS >= 15000 )) || {
    echo "Real-microphone proof requires at least a 15000ms evidence window." >&2
    exit 1
  }
fi
if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
  MUTE_CALLEE_DURING_HOOK_JSON=true
else
  MUTE_CALLEE_DURING_HOOK_JSON=false
fi
[[ "$($ADB -s "$PTT_ANDROID_DEVICE" get-state 2>/dev/null || true)" == device ]] || {
  echo "Android device is offline or unauthorized: $PTT_ANDROID_DEVICE" >&2
  exit 1
}
[[ "$($ADB -s "$PTT_ANDROID_DEVICE" shell getprop ro.kernel.qemu | tr -d '\r[:space:]')" != 1 ]] || {
  echo "A physical Android device is required." >&2
  exit 1
}
"$ADB" -s "$PTT_ANDROID_DEVICE" shell pm path "$ANDROID_PACKAGE" >/dev/null || {
  echo "The Android debug product app is not installed." >&2
  exit 1
}
"$ROOT/scripts/assert-ios-device-unlocked.sh" "$PTT_IOS_DEVICE"

bounded() { node "$ROOT/scripts/run-with-timeout.mjs" "$DEVICE_TIMEOUT" "$@"; }

ios_apps="$WORK_DIR/ios-apps.json"
bounded xcrun devicectl device info apps --device "$PTT_IOS_DEVICE" --bundle-id "$IOS_BUNDLE" \
  --json-output "$ios_apps" >/dev/null
ruby -rjson -e '
  result = JSON.parse(File.read(ARGV[0])).fetch("result", {})
  apps = result["apps"] || result["applications"] || []
  abort "missing iOS product app" unless apps.any? { |app| [app["bundleIdentifier"], app["bundleID"]].include?(ARGV[1]) }
' "$ios_apps" "$IOS_BUNDLE"

decode_fixture() {
  printf '%s' "$1" | openssl base64 -d -A -out "$2"
  jq -e '(.identityKeyPair | length) >= 80 and .registrationId >= 1 and .registrationId <= 16383' "$2" >/dev/null
}
decode_fixture "$PTT_ANDROID_IDENTITY_FIXTURE" "$WORK_DIR/android-identity.json"
decode_fixture "$PTT_IOS_IDENTITY_FIXTURE" "$WORK_DIR/ios-identity.json"

copy_android_file() {
  local source="$1" name="$2" remote
  remote="/data/local/tmp/ptt-physical-call-$name-$(uuidgen)"
  "$ADB" -s "$PTT_ANDROID_DEVICE" push "$source" "$remote" >/dev/null
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell run-as "$ANDROID_PACKAGE" mkdir -p files
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell run-as "$ANDROID_PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell rm "$remote"
}

read_android_marker() {
  "$ADB" -s "$PTT_ANDROID_DEVICE" exec-out run-as "$ANDROID_PACKAGE" \
    cat "files/ptt-e2e-$1.txt" 2>/dev/null | tr -d '\r\n' || true
}

read_ios_marker() {
  [[ -f "$IOS_CONSOLE" ]] || return 0
  awk -v marker_name="$1" -f "$ROOT/scripts/read-ios-console-marker.awk" "$IOS_CONSOLE"
}

read_marker() {
  if [[ "$1" == android ]]; then read_android_marker "$2"; else read_ios_marker "$2"; fi
}

complete_callee_hook() {
  if [[ "$callee_platform" == android ]]; then
    "$ADB" -s "$PTT_ANDROID_DEVICE" shell run-as "$ANDROID_PACKAGE" \
      sh -c "'printf complete > files/ptt-e2e-call-hook-complete.txt'"
  else
    local marker="$WORK_DIR/call-hook-complete.txt"
    printf complete >"$marker"
    bounded xcrun devicectl device copy to --device "$PTT_IOS_DEVICE" \
      --source "$marker" --destination Documents/ptt-e2e-call-hook-complete.txt \
      --domain-type appDataContainer --domain-identifier "$IOS_BUNDLE" >/dev/null
  fi
}

report_diagnostics() {
  if [[ "$1" == android ]]; then
    "$ADB" -s "$PTT_ANDROID_DEVICE" logcat -d -v brief 2>/dev/null |
      grep -E 'PTT_E2E|PTT_CALL|AndroidRuntime' | tail -120 |
      sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}/[redacted-uuid]/g' >&2 || true
  elif [[ -f "$IOS_CONSOLE" ]]; then
    grep -E 'PTT_E2E|fatal|crash|exception|error|failed' "$IOS_CONSOLE" | tail -140 |
      sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}/[redacted-uuid]/g' >&2 || true
  fi
}

wait_marker() {
  local platform="$1" name="$2" expected="$3" timeout="$4" value="" deadline
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    value="$(read_marker "$platform" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "$platform physical call marker $name did not reach $expected (last value: $value)." >&2
  report_diagnostics "$platform"
  return 1
}

prepare_android() {
  local mode="$1" role="$2" peer="$3" call_id="${4:-}" preserve="${5:-false}" wait_prewarm="${6:-false}"
  local mute_during_proof="${7:-false}"
  local config="$WORK_DIR/android-config.json"
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell run-as "$ANDROID_PACKAGE" sh -c "'rm -f files/ptt-e2e-*.txt'" >/dev/null
  jq -cn --arg role "$role" --arg mode "$mode" --arg server "$PTT_CALL_SERVER" \
    --arg aci "$PTT_ANDROID_ACI" --arg mailbox "$PTT_ANDROID_MAILBOX" --arg token "$PTT_ANDROID_TOKEN" \
    --arg channel "$PTT_CALL_CONVERSATION_ID" --arg run "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg peerAci "$peer" --arg callId "$call_id" --argjson device "$PTT_ANDROID_DEVICE_ID" \
    --argjson preserveState "$preserve" --argjson waitForPrewarm "$wait_prewarm" \
    --argjson diagnosticCallAudio "$DIAGNOSTIC_AUDIO" \
    --argjson forceCallSpeaker "$FORCE_ANDROID_SPEAKER" \
    --argjson muteDuringProof "$mute_during_proof" \
    --argjson callProofDurationMs "$CALL_PROOF_DURATION_MS" \
    --argjson skipCryptoInitialization "$([[ "$mode" == call-prepare ]] && echo false || echo true)" \
    '{role:$role,mode:$mode,serverUrl:$server,aci:$aci,deviceId:$device,mailboxId:$mailbox,
      accessToken:$token,channelId:$channel,run:$run,transmissions:1,peerAci:$peerAci,
      callId:$callId,preserveState:$preserveState,waitForPrewarm:$waitForPrewarm,
      skipCryptoInitialization:$skipCryptoInitialization,diagnosticCallAudio:$diagnosticCallAudio,
      forceCallSpeaker:$forceCallSpeaker,callProofDurationMs:$callProofDurationMs,
      muteDuringProof:$muteDuringProof}' >"$config"
  copy_android_file "$WORK_DIR/android-identity.json" ptt-e2e-identity.json
  copy_android_file "$config" ptt-e2e-config.json
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell am force-stop "$ANDROID_PACKAGE"
  "$ADB" -s "$PTT_ANDROID_DEVICE" logcat -c
  "$ADB" -s "$PTT_ANDROID_DEVICE" shell am start -n "$ANDROID_ACTIVITY" >/dev/null
}

install_ios_fixture() {
  bounded xcrun devicectl device copy to --device "$PTT_IOS_DEVICE" \
    --source "$WORK_DIR/ios-identity.json" --destination Documents/ptt-e2e-identity.json \
    --domain-type appDataContainer --domain-identifier "$IOS_BUNDLE" >/dev/null
}

launch_ios() {
  local role="$1" peer="$2" call_id="${3:-}" environment
  environment="$(jq -cn --arg token "$PTT_IOS_TOKEN" --arg aci "$PTT_IOS_ACI" \
    --arg mailbox "$PTT_IOS_MAILBOX" --arg device "$PTT_IOS_DEVICE_ID" \
    --arg peer "$peer" --arg callId "$call_id" --arg diagnosticAudio "$DIAGNOSTIC_AUDIO" \
    --arg proofDuration "$CALL_PROOF_DURATION_MS" \
    --arg muteDuringProof "$MUTE_CALLEE_DURING_HOOK" \
    '{PTT_E2E_ACCESS_TOKEN:$token,PTT_E2E_ACI:$aci,PTT_E2E_MAILBOX:$mailbox,
      PTT_E2E_DEVICE:$device,PTT_CALL_PEER_ACI:$peer,PTT_CALL_ID:$callId,
      PTT_CALL_DIAGNOSTIC_AUDIO:$diagnosticAudio,PTT_CALL_PROOF_DURATION_MS:$proofDuration,
      PTT_CALL_MUTE_DURING_PROOF:$muteDuringProof}')"
  if [[ "$IOS_CONSOLE_PID" =~ ^[0-9]+$ ]]; then
    kill -TERM "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
  fi
  IOS_CONSOLE="$WORK_DIR/ios-console-$(uuidgen).log"
  xcrun devicectl device process launch --device "$PTT_IOS_DEVICE" --terminate-existing --activate --console \
    --environment-variables "$environment" "$IOS_BUNDLE" --ptt-server "$PTT_CALL_SERVER" \
    "--ptt-e2e-$role" --ptt-e2e-reset-crypto --ptt-e2e-skip-voice \
    "--ptt-e2e-call-$([[ "$role" == sender ]] && echo caller || echo callee)" \
    >"$IOS_CONSOLE" 2>&1 &
  IOS_CONSOLE_PID=$!
}

wait_call_id() {
  local platform="$1" state=""
  for _ in {1..90}; do
    CALL_ID="$(read_marker "$platform" call-id)"
    [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && return 0
    state="$(read_marker "$platform" call-state)"
    [[ "$state" == fail:* ]] && break
    sleep 1
  done
  echo "$platform caller did not create a physical cross-platform call (last state: $state)." >&2
  report_diagnostics "$platform"
  return 1
}

wait_android_service_release() {
  for _ in {1..30}; do
    if ! "$ADB" -s "$PTT_ANDROID_DEVICE" shell dumpsys activity services "$ANDROID_PACKAGE" 2>/dev/null |
      grep -q CallSessionService; then return 0; fi
    sleep 1
  done
  echo "Android retained call audio ownership after cross-platform teardown." >&2
  return 1
}

"$ADB" -s "$PTT_ANDROID_DEVICE" shell pm grant "$ANDROID_PACKAGE" android.permission.RECORD_AUDIO >/dev/null
"$ADB" -s "$PTT_ANDROID_DEVICE" shell pm grant "$ANDROID_PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
install_ios_fixture

# Android needs a durable prekey/session store before the call-specific launch.
prepare_android call-prepare "$([[ "$PTT_CALL_DIRECTION" == android-to-ios ]] && echo sender || echo receiver)" \
  "$PTT_IOS_ACI" "" false false
wait_marker android "$([[ "$PTT_CALL_DIRECTION" == android-to-ios ]] && echo sender-state || echo receiver-state)" pass 120

if [[ "$PTT_CALL_DIRECTION" == android-to-ios ]]; then
  CALLER_TOKEN="$PTT_ANDROID_TOKEN"
  prepare_android call-caller sender "$PTT_IOS_ACI" "" true false
  wait_call_id android
  launch_ios receiver "$PTT_ANDROID_ACI" "$CALL_ID"
  caller_platform=android
  callee_platform=ios
else
  CALLER_TOKEN="$PTT_IOS_TOKEN"
  launch_ios sender "$PTT_ANDROID_ACI"
  wait_call_id ios
  prepare_android call-callee receiver "$PTT_IOS_ACI" "$CALL_ID" true true \
    "$MUTE_CALLEE_DURING_HOOK_JSON"
  caller_platform=ios
  callee_platform=android
fi

if [[ -n "$ACTIVE_HOOK" ]]; then
  for platform in "$caller_platform" "$callee_platform"; do
    active_at=""
    for _ in {1..150}; do
      active_at="$(read_marker "$platform" call-active-at-ms)"
      [[ "$active_at" =~ ^[0-9]{13}$ ]] && break
      state="$(read_marker "$platform" call-state)"
      [[ "$state" == fail:* ]] && {
        echo "$platform call failed before the active-call hook: $state" >&2
        report_diagnostics "$platform"
        exit 1
      }
      sleep 1
    done
    [[ "$active_at" =~ ^[0-9]{13}$ ]] || {
      echo "$platform call did not become protected and active before the hook." >&2
      report_diagnostics "$platform"
      exit 1
    }
  done
  if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
    wait_marker "$callee_platform" call-muted true 30
  fi
  if [[ "$callee_platform" == android && "$ATTENUATE_ANDROID_CALLEE_OUTPUT" == 1 ]]; then
    ANDROID_OUTPUT_ORIGINAL_VOLUME="$(
      "$ADB" -s "$PTT_ANDROID_DEVICE" shell cmd media_session volume --stream 0 --get 2>/dev/null |
        sed -nE 's/.*volume is ([0-9]+) in range.*/\1/p' | tail -1
    )"
    [[ "$ANDROID_OUTPUT_ORIGINAL_VOLUME" =~ ^[0-9]+$ ]] || {
      echo "Could not read the Android callee voice-call volume for directional isolation." >&2
      exit 1
    }
    "$ADB" -s "$PTT_ANDROID_DEVICE" shell cmd media_session volume --stream 0 --set 1 >/dev/null
  fi
  hook_status=0
  PTT_CALL_ACTIVE_CALLER_PLATFORM="$caller_platform" \
  PTT_CALL_ACTIVE_CALLEE_PLATFORM="$callee_platform" \
    "$ACTIVE_HOOK" || hook_status=$?
  restore_android_output_volume
  if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
    complete_callee_hook
    wait_marker "$callee_platform" call-muted false 30
  fi
  (( hook_status == 0 )) || exit "$hook_status"
fi
wait_marker "$caller_platform" call-state pass 150
wait_marker "$callee_platform" call-state pass 150

if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  capture_bursts="$(read_marker "$caller_platform" call-capture-tone-bursts)"
  capture_peak="$(read_marker "$caller_platform" call-capture-peak-rms)"
  render_bursts="$(read_marker "$callee_platform" call-render-tone-bursts)"
  render_peak="$(read_marker "$callee_platform" call-render-peak-rms)"
  capture_format="$(read_marker "$caller_platform" call-capture-format)"
  render_format="$(read_marker "$callee_platform" call-render-format)"
  [[ "$capture_bursts" == 5 ]] || {
    echo "$caller_platform microphone captured ${capture_bursts:-0}/5 diagnostic tone bursts (peak RMS ${capture_peak:-0})." >&2
    exit 1
  }
  [[ "$render_bursts" == 5 ]] || {
    echo "$callee_platform playback graph received ${render_bursts:-0}/5 microphone-originated tone bursts (peak RMS ${render_peak:-0})." >&2
    exit 1
  }
  [[ "$capture_format" != DISABLED && "$render_format" != DISABLED ]] || {
    echo "Real-microphone diagnostics did not attach to both cross-platform WebRTC audio graphs." >&2
    exit 1
  }
  echo "$PTT_CALL_DIRECTION carried all five physical microphone tones into the remote decrypted render graph."
fi
created_ms="$(read_marker "$caller_platform" call-created-at-ms)"
ringing_ms="$(read_marker "$callee_platform" call-ringing-at-ms)"
answered_ms="$(read_marker "$callee_platform" call-answered-at-ms)"
caller_media_ms="$(read_marker "$caller_platform" call-media-connected-at-ms)"
callee_media_ms="$(read_marker "$callee_platform" call-media-connected-at-ms)"
for value in "$created_ms" "$ringing_ms" "$answered_ms" "$caller_media_ms" "$callee_media_ms"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "A physical cross-call timing marker is missing." >&2; exit 1; }
done
invite_to_ring_ms=$((ringing_ms - created_ms))
answer_to_media_ms=$(( (caller_media_ms > callee_media_ms ? caller_media_ms : callee_media_ms) - answered_ms ))
(( invite_to_ring_ms >= 0 && invite_to_ring_ms <= MAX_INVITE_TO_RING_MS )) || {
  echo "$PTT_CALL_DIRECTION invite-to-ring was ${invite_to_ring_ms}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2
  exit 1
}
(( answer_to_media_ms >= 0 && answer_to_media_ms <= MAX_ANSWER_TO_MEDIA_MS )) || {
  echo "$PTT_CALL_DIRECTION answer-to-protected-media was ${answer_to_media_ms}ms (limit ${MAX_ANSWER_TO_MEDIA_MS}ms)." >&2
  exit 1
}

curl -fsS -H "Authorization: Bearer $CALLER_TOKEN" -H 'Content-Type: application/json' \
  -d '{}' "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
wait_marker ios call-teardown pass 30
wait_android_service_release
CALL_ID=""
echo "$PTT_CALL_DIRECTION physical encrypted call passed CallKit, Core-Telecom, E2EE media and teardown (invite-to-ring ${invite_to_ring_ms}ms, answer-to-media ${answer_to_media_ms}ms)."
