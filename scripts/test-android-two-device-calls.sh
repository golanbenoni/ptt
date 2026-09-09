#!/usr/bin/env bash
# Drive a real encrypted 1:1 call through two Android runtimes. This validates
# Core-Telecom registration, account/API state, Double Ratchet key exchange,
# LiveKit E2EE connection, audio activation, and remote teardown. External
# acoustic capture is still required for release evidence.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
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
PACKAGE="app.ptt.talk.debug"
ACTIVITY="$PACKAGE/app.ptt.talk.PhysicalE2EActivity"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_ACTIVE_MS="${PTT_CALL_MAX_ANSWER_TO_ACTIVE_MS:-15000}"
WORK_DIR="$(mktemp -d -t ptt-android-call.XXXXXX)"
CALL_ID=""
REVERSED_PORTS=()

cleanup() {
  if [[ -n "$CALL_ID" ]]; then
    curl -sS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
      -H 'Content-Type: application/json' -d '{}' \
      "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  local serial port
  for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
    "$ADB" -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    for port in "${REVERSED_PORTS[@]}"; do
      "$ADB" -s "$serial" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
    done
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

for command in jq openssl uuidgen curl; do
  command -v "$command" >/dev/null || { echo "Missing call-test dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -f "$APK" || { echo "Android debug automation APK was not found: $APK" >&2; exit 1; }
[[ "$PTT_ANDROID_DEVICE_1" != "$PTT_ANDROID_DEVICE_2" ]] || {
  echo "Two different Android runtimes are required." >&2
  exit 1
}
[[ "$PTT_CALL_SERVER" =~ ^http://(127\.0\.0\.1|localhost):([1-9][0-9]{1,4})$ ]] || {
  echo "The device call driver requires a loopback HTTP control origin reached through adb reverse." >&2
  exit 1
}
CONTROL_PORT="${BASH_REMATCH[2]}"
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_ACTIVE_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}

decode_fixture() {
  printf '%s' "$1" | openssl base64 -d -A -out "$2"
  jq -e '(.identityKeyPair | length) >= 80 and .registrationId >= 1 and .registrationId <= 16383' "$2" >/dev/null
}

require_runtime() {
  local serial="$1"
  [[ "$($ADB -s "$serial" get-state 2>/dev/null || true)" == device ]] || {
    echo "Android runtime $serial is offline, unauthorized, or unavailable." >&2
    return 1
  }
}

copy_private_file() {
  local serial="$1" source="$2" name="$3" remote
  remote="/data/local/tmp/ptt-call-$name-$(uuidgen)"
  "$ADB" -s "$serial" push "$source" "$remote" >/dev/null
  "$ADB" -s "$serial" shell run-as "$PACKAGE" mkdir -p files
  "$ADB" -s "$serial" shell run-as "$PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$serial" shell rm "$remote"
}

read_marker() {
  "$ADB" -s "$1" exec-out run-as "$PACKAGE" cat "files/ptt-e2e-$2.txt" 2>/dev/null | tr -d '\r\n' || true
}

prepare_role() {
  local serial="$1" role="$2" mode="$3" aci="$4" device_id="$5" mailbox="$6" token="$7"
  local fixture="$8" call_id="${9:-}" config="$WORK_DIR/config-$role.json"
  "$ADB" -s "$serial" shell run-as "$PACKAGE" sh -c "'rm -f files/ptt-e2e-*.txt'" >/dev/null
  jq -cn \
    --arg role "$role" --arg mode "$mode" --arg server "$PTT_CALL_SERVER" \
    --arg aci "$aci" --arg mailbox "$mailbox" --arg token "$token" \
    --arg channel "$PTT_CALL_CONVERSATION_ID" --arg run "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg peerAci "$PTT_CALL_CALLEE_ACI" --arg callId "$call_id" --argjson device "$device_id" \
    '{role:$role,mode:$mode,serverUrl:$server,aci:$aci,deviceId:$device,mailboxId:$mailbox,
      accessToken:$token,channelId:$channel,run:$run,transmissions:1,peerAci:$peerAci,callId:$callId}' \
    > "$config"
  copy_private_file "$serial" "$fixture" ptt-e2e-identity.json
  copy_private_file "$serial" "$config" ptt-e2e-config.json
}

launch_role() {
  "$ADB" -s "$1" shell am force-stop "$PACKAGE"
  "$ADB" -s "$1" logcat -c
  "$ADB" -s "$1" shell am start -n "$ACTIVITY" >/dev/null
}

wait_marker() {
  local serial="$1" name="$2" expected="$3" attempts="$4" value=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(read_marker "$serial" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "Android call marker $name did not reach $expected on $serial (last value: $value)." >&2
  "$ADB" -s "$serial" logcat -d -v brief 2>/dev/null | grep -E 'PTT_E2E|AndroidRuntime' | tail -80 |
    sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}/[redacted-uuid]/g' >&2 || true
  return 1
}

decode_fixture "$PTT_CALL_CALLER_IDENTITY_FIXTURE" "$WORK_DIR/caller-identity.json"
decode_fixture "$PTT_CALL_CALLEE_IDENTITY_FIXTURE" "$WORK_DIR/callee-identity.json"
for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
  require_runtime "$serial"
  if [[ "${PTT_ANDROID_SKIP_INSTALL:-0}" != 1 ]]; then
    "$ADB" -s "$serial" install -r -t "$APK" >/dev/null
  else
    "$ADB" -s "$serial" shell pm path "$PACKAGE" >/dev/null || {
      echo "Android runtime $serial does not have the requested preinstalled debug app." >&2
      exit 1
    }
  fi
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO >/dev/null
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
done

IFS=',' read -r -a REVERSED_PORTS <<<"${PTT_CALL_REVERSE_PORTS:-$CONTROL_PORT,7880,7881}"
for port in "${REVERSED_PORTS[@]}"; do
  [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Invalid adb reverse port: $port" >&2; exit 1; }
  for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
    "$ADB" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null
  done
done

prepare_role "$PTT_ANDROID_DEVICE_1" sender call-caller "$PTT_CALL_CALLER_ACI" 1 \
  "$PTT_CALL_CALLER_MAILBOX" "$PTT_CALL_CALLER_TOKEN" "$WORK_DIR/caller-identity.json"
launch_role "$PTT_ANDROID_DEVICE_1"
for _ in {1..60}; do
  CALL_ID="$(read_marker "$PTT_ANDROID_DEVICE_1" call-id)"
  [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && break
  caller_state="$(read_marker "$PTT_ANDROID_DEVICE_1" call-state)"
  [[ "$caller_state" == fail:* ]] && { echo "Caller failed before invitation: $caller_state" >&2; exit 1; }
  sleep 1
done
[[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "Caller did not create an opaque call." >&2; exit 1; }

prepare_role "$PTT_ANDROID_DEVICE_2" receiver call-callee "$PTT_CALL_CALLEE_ACI" 1 \
  "$PTT_CALL_CALLEE_MAILBOX" "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/callee-identity.json" "$CALL_ID"
launch_role "$PTT_ANDROID_DEVICE_2"
wait_marker "$PTT_ANDROID_DEVICE_1" call-state pass 150
wait_marker "$PTT_ANDROID_DEVICE_2" call-state pass 150

created_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-created-at-ms)"
ringing_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-ringing-at-ms)"
caller_active_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-active-at-ms)"
callee_active_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-active-at-ms)"
for value in "$created_ms" "$ringing_ms" "$caller_active_ms" "$callee_active_ms"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "A required call timing marker is missing." >&2; exit 1; }
done
invite_to_ring_ms=$((ringing_ms - created_ms))
answer_to_active_ms=$(( (caller_active_ms > callee_active_ms ? caller_active_ms : callee_active_ms) - ringing_ms ))
(( invite_to_ring_ms >= 0 && invite_to_ring_ms <= MAX_INVITE_TO_RING_MS )) || {
  echo "Invite-to-ring latency was ${invite_to_ring_ms}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2
  exit 1
}
(( answer_to_active_ms >= 0 && answer_to_active_ms <= MAX_ANSWER_TO_ACTIVE_MS )) || {
  echo "Answer-to-protected-audio readiness was ${answer_to_active_ms}ms (limit ${MAX_ANSWER_TO_ACTIVE_MS}ms)." >&2
  exit 1
}

curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
for _ in {1..30}; do
  state="$(curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
    "$PTT_CALL_SERVER/v1/calls/$CALL_ID" | jq -r .state)"
  [[ "$state" == ended ]] && break
  sleep 1
done
[[ "$state" == ended ]] || { echo "The host end action did not terminate the call." >&2; exit 1; }
reason="$(curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID" | jq -r .endReason)"
[[ "$reason" == host_ended ]] || { echo "Active call ended with unexpected reason: $reason" >&2; exit 1; }

for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
  for _ in {1..30}; do
    if ! "$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE" 2>/dev/null |
      grep -q 'CallSessionService'; then
      break
    fi
    sleep 1
  done
  if "$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE" 2>/dev/null |
    grep -q 'CallSessionService'; then
    echo "Call audio ownership was not released on $serial." >&2
    exit 1
  fi
done

echo "Two-device Android encrypted call passed: Core-Telecom audio activated, both endpoints stayed protected and unmuted, and remote teardown completed (invite-to-ring ${invite_to_ring_ms}ms, answer-to-active ${answer_to_active_ms}ms)."
