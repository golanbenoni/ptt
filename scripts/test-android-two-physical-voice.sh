#!/usr/bin/env bash
# Run deterministic encrypted PTT through two dedicated physical Android devices.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"
: "${PTT_E2E_ACI:?PTT_E2E_ACI is required}"
: "${PTT_E2E_CHANNEL_ID:?PTT_E2E_CHANNEL_ID is required}"
: "${PTT_E2E_SENDER_MAILBOX:?PTT_E2E_SENDER_MAILBOX is required}"
: "${PTT_E2E_RECEIVER_MAILBOX:?PTT_E2E_RECEIVER_MAILBOX is required}"
: "${PTT_E2E_SENDER_TOKEN:?PTT_E2E_SENDER_TOKEN is required}"
: "${PTT_E2E_RECEIVER_TOKEN:?PTT_E2E_RECEIVER_TOKEN is required}"
: "${PTT_E2E_SENDER_IDENTITY_FIXTURE:?PTT_E2E_SENDER_IDENTITY_FIXTURE is required}"
: "${PTT_E2E_RECEIVER_IDENTITY_FIXTURE:?PTT_E2E_RECEIVER_IDENTITY_FIXTURE is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
APK="${PTT_ANDROID_AUTOMATION_APK:-$ROOT/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
PACKAGE="app.ptt.talk.debug"
ACTIVITY="$PACKAGE/app.ptt.talk.PhysicalE2EActivity"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
MAX_FLOOR_LATENCY_MS="${PTT_E2E_MAX_FLOOR_LATENCY_MS:-150}"
MAX_READY_LATENCY_MS="${PTT_E2E_MAX_READY_LATENCY_MS:-400}"
WORK_DIR="$(mktemp -d -t ptt-android-physical.XXXXXX)"
TOUCHED_ANDROID_DEVICES=()

cleanup() {
  for serial in "${TOUCHED_ANDROID_DEVICES[@]}"; do
    "$ADB" -s "$serial" shell svc wifi enable >/dev/null 2>&1 || true
    wake_android "$serial" || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -f "$APK" || { echo "Android debug automation APK was not found: $APK" >&2; exit 1; }
if [[ "$PTT_ANDROID_DEVICE_1" == "$PTT_ANDROID_DEVICE_2" ]]; then
  echo "Physical Android validation requires two different devices." >&2
  exit 1
fi
if [[ ! "$TRANSMISSIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_E2E_TRANSMISSIONS must be a positive integer." >&2
  exit 1
fi

decode_fixture() {
  local encoded="$1"
  local output="$2"
  printf '%s' "$encoded" | openssl base64 -d -A -out "$output"
  jq -e '.identityKeyPair | length >= 80' "$output" >/dev/null
  jq -e '.registrationId >= 1 and .registrationId <= 16383' "$output" >/dev/null
}

require_device() {
  local serial="$1"
  local state
  state="$($ADB -s "$serial" get-state 2>/dev/null || true)"
  [[ "$state" == device ]] || {
    echo "Android device $serial is offline, unauthorized, or unavailable." >&2
    return 1
  }
}

install_debug_app() {
  local serial="$1"
  "$ADB" -s "$serial" install -r -t "$APK" >/dev/null
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO >/dev/null
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
}

copy_private_file() {
  local serial="$1"
  local source="$2"
  local name="$3"
  local remote
  remote="/data/local/tmp/ptt-${name}-$(uuidgen)"
  "$ADB" -s "$serial" push "$source" "$remote" >/dev/null
  "$ADB" -s "$serial" shell run-as "$PACKAGE" mkdir -p files
  "$ADB" -s "$serial" shell run-as "$PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$serial" shell rm "$remote"
}

write_config() {
  local output="$1"
  local role="$2"
  local device_id="$3"
  local mailbox="$4"
  local token="$5"
  local run="$6"
  local mode="${7:-matrix}"
  local preserve_state="${8:-false}"
  jq -cn \
    --arg role "$role" \
    --arg server "$PTT_E2E_SERVER" \
    --arg aci "$PTT_E2E_ACI" \
    --arg channel "$PTT_E2E_CHANNEL_ID" \
    --arg mailbox "$mailbox" \
    --arg token "$token" \
    --arg run "$run" \
    --arg mode "$mode" \
    --argjson preserveState "$preserve_state" \
    --argjson device "$device_id" \
    --argjson transmissions "$TRANSMISSIONS" \
    '{role:$role,serverUrl:$server,aci:$aci,channelId:$channel,mailboxId:$mailbox,accessToken:$token,deviceId:$device,run:$run,transmissions:$transmissions,mode:$mode,preserveState:$preserveState}' \
    > "$output"
}

launch_role() {
  local serial="$1"
  "$ADB" -s "$serial" shell am force-stop "$PACKAGE"
  "$ADB" -s "$serial" shell am start -n "$ACTIVITY" >/dev/null
}

android_is_awake() {
  local power
  power="$("$ADB" -s "$1" shell dumpsys power 2>/dev/null)"
  if grep -q 'Display Power: state=' <<<"$power"; then
    grep -q 'Display Power: state=ON' <<<"$power"
  else
    grep -Eq 'mWakefulness=Awake|mScreenOn=true' <<<"$power"
  fi
}

wake_android() {
  local serial="$1"
  if ! android_is_awake "$serial"; then
    "$ADB" -s "$serial" shell input keyevent 26 >/dev/null
  fi
  "$ADB" -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
}

prepare_receiver_lifecycle() {
  local label="$1"
  local serial="$2"
  TOUCHED_ANDROID_DEVICES+=("$serial")
  if [[ "${PTT_PHYSICAL_ANDROID_NETWORK_TRANSITION:-0}" == 1 ]]; then
    echo "Cycling $label receiver Wi-Fi before transmission to force network rebinding"
    "$ADB" -s "$serial" shell svc wifi disable
    sleep 5
    "$ADB" -s "$serial" shell svc wifi enable
    sleep 15
  fi
  if [[ "${PTT_PHYSICAL_ANDROID_SCREEN_OFF:-0}" == 1 ]]; then
    wake_android "$serial"
    "$ADB" -s "$serial" shell input keyevent 26 >/dev/null
    sleep 2
    if android_is_awake "$serial"; then
      echo "$label receiver did not enter screen-off state." >&2
      return 1
    fi
    echo "$label receiver screen is off; encrypted playback must remain audible"
  fi
}

read_marker() {
  local serial="$1"
  local name="$2"
  "$ADB" -s "$serial" exec-out run-as "$PACKAGE" cat "files/ptt-e2e-$name.txt" 2>/dev/null |
    tr -d '\r\n' || true
}

prepare_role() {
  local serial="$1"
  local fixture="$2"
  local role="$3"
  local device_id="$4"
  local mailbox="$5"
  local token="$6"
  local run="$7"
  local mode="${8:-matrix}"
  local preserve_state="${9:-false}"
  local config="$WORK_DIR/config-$serial-$role.json"
  write_config "$config" "$role" "$device_id" "$mailbox" "$token" "$run" "$mode" "$preserve_state"
  copy_private_file "$serial" "$fixture" ptt-e2e-identity.json
  copy_private_file "$serial" "$config" ptt-e2e-config.json
}

run_process_restart_delivery() {
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  echo "Starting Android receiver for process-death delivery gate"
  prepare_role "$PTT_ANDROID_DEVICE_2" "$WORK_DIR/device-2.json" receiver 2 \
    "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" "$run" restart-receiver false
  launch_role "$PTT_ANDROID_DEVICE_2"

  echo "Queueing Android message behind an injected delivery interruption"
  prepare_role "$PTT_ANDROID_DEVICE_1" "$WORK_DIR/device-1.json" sender 1 \
    "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$run" queue-before-crash false
  launch_role "$PTT_ANDROID_DEVICE_1"
  for _ in {1..90}; do
    local state count
    state="$(read_marker "$PTT_ANDROID_DEVICE_1" chat-restart-sender-state)"
    count="$(read_marker "$PTT_ANDROID_DEVICE_1" chat-restart-sender-count)"
    [[ "$state" == fail:* ]] && { echo "Android process-death queue failed: $state" >&2; return 1; }
    [[ "$state" == queued && "$count" == 1 ]] && break
    sleep 1
  done
  if [[ "$(read_marker "$PTT_ANDROID_DEVICE_1" chat-restart-sender-state)" != queued ]]; then
    echo "Android message was not durably queued before process termination." >&2
    return 1
  fi

  echo "Force-stopping and relaunching Android sender to prove durable retry"
  "$ADB" -s "$PTT_ANDROID_DEVICE_1" shell am force-stop "$PACKAGE"
  prepare_role "$PTT_ANDROID_DEVICE_1" "$WORK_DIR/device-1.json" sender 1 \
    "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$run" resume-after-crash true
  launch_role "$PTT_ANDROID_DEVICE_1"
  for _ in {1..150}; do
    local sender_state receiver_state receiver_count
    sender_state="$(read_marker "$PTT_ANDROID_DEVICE_1" chat-restart-sender-state)"
    receiver_state="$(read_marker "$PTT_ANDROID_DEVICE_2" chat-restart-receiver-state)"
    receiver_count="$(read_marker "$PTT_ANDROID_DEVICE_2" chat-restart-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ]]; then
      echo "Android process-death retry failed: sender=$sender_state receiver=$receiver_state" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$receiver_state" == pass && "$receiver_count" == 1 ]]; then
      echo "Android process-death gate passed: encrypted outbox retried after relaunch"
      return 0
    fi
    sleep 1
  done
  echo "Android process-death retry timed out." >&2
  return 1
}

wait_receiver_ready() {
  local label="$1"
  local serial="$2"
  local state=""
  for _ in {1..90}; do
    state="$(read_marker "$serial" receiver-state)"
    [[ "$state" == ready ]] && return 0
    if [[ "$state" == fail:* ]]; then
      echo "$label receiver setup failed: $state" >&2
      return 1
    fi
    sleep 1
  done
  echo "$label receiver did not become ready within 90 seconds (last state: $state)." >&2
  return 1
}

run_direction() {
  local label="$1"
  local sender_serial="$2"
  local sender_id="$3"
  local sender_mailbox="$4"
  local sender_token="$5"
  local sender_fixture="$6"
  local receiver_serial="$7"
  local receiver_id="$8"
  local receiver_mailbox="$9"
  local receiver_token="${10}"
  local receiver_fixture="${11}"
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  prepare_role "$receiver_serial" "$receiver_fixture" receiver "$receiver_id" "$receiver_mailbox" "$receiver_token" "$run"
  launch_role "$receiver_serial"
  wait_receiver_ready "$label" "$receiver_serial"
  prepare_receiver_lifecycle "$label" "$receiver_serial"
  prepare_role "$sender_serial" "$sender_fixture" sender "$sender_id" "$sender_mailbox" "$sender_token" "$run"
  launch_role "$sender_serial"

  local sender_state="" receiver_state="" sender_count="" receiver_count=""
  local chat_sender_state="" chat_receiver_state="" chat_sender_count="" chat_receiver_count=""
  for attempt in {1..180}; do
    sender_state="$(read_marker "$sender_serial" sender-state)"
    receiver_state="$(read_marker "$receiver_serial" receiver-state)"
    sender_count="$(read_marker "$sender_serial" sender-count)"
    receiver_count="$(read_marker "$receiver_serial" receiver-count)"
    chat_sender_state="$(read_marker "$sender_serial" chat-sender-state)"
    chat_receiver_state="$(read_marker "$receiver_serial" chat-receiver-state)"
    chat_sender_count="$(read_marker "$sender_serial" chat-sender-count)"
    chat_receiver_count="$(read_marker "$receiver_serial" chat-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ||
          "$chat_sender_state" == fail:* || "$chat_receiver_state" == fail:* ]]; then
      echo "$label failed: voice sender=$sender_state/$sender_count receiver=$receiver_state/$receiver_count; chat sender=$chat_sender_state/$chat_sender_count receiver=$chat_receiver_state/$chat_receiver_count" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$sender_count" == "$TRANSMISSIONS" &&
          "$receiver_state" == pass && "$receiver_count" == "$TRANSMISSIONS" &&
          "$chat_sender_state" == pass && "$chat_sender_count" == 14 &&
          "$chat_receiver_state" == pass && "$chat_receiver_count" == 14 ]]; then
      "$ROOT/scripts/assert-latency-samples.sh" "$label floor grant" \
        "$(read_marker "$sender_serial" floor-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_FLOOR_LATENCY_MS"
      "$ROOT/scripts/assert-latency-samples.sh" "$label communication ready" \
        "$(read_marker "$sender_serial" ready-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_READY_LATENCY_MS"
      echo "$label passed $TRANSMISSIONS encrypted PTT transmissions and the encrypted chat matrix"
      wake_android "$receiver_serial"
      return 0
    fi
    if (( attempt % 15 == 0 )); then
      echo "Waiting $label: voice sender=$sender_state/$sender_count receiver=$receiver_state/$receiver_count; chat sender=$chat_sender_state/$chat_sender_count receiver=$chat_receiver_state/$chat_receiver_count"
    fi
    sleep 1
  done
  echo "$label timed out before AudioTrack playback-head completion." >&2
  return 1
}

decode_fixture "$PTT_E2E_SENDER_IDENTITY_FIXTURE" "$WORK_DIR/device-1.json"
decode_fixture "$PTT_E2E_RECEIVER_IDENTITY_FIXTURE" "$WORK_DIR/device-2.json"
require_device "$PTT_ANDROID_DEVICE_1"
require_device "$PTT_ANDROID_DEVICE_2"
install_debug_app "$PTT_ANDROID_DEVICE_1"
install_debug_app "$PTT_ANDROID_DEVICE_2"

run_direction device-1-to-device-2 \
  "$PTT_ANDROID_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$WORK_DIR/device-1.json" \
  "$PTT_ANDROID_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" "$WORK_DIR/device-2.json"
run_direction device-2-to-device-1 \
  "$PTT_ANDROID_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" "$WORK_DIR/device-2.json" \
  "$PTT_ANDROID_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$WORK_DIR/device-1.json"
run_process_restart_delivery

echo "Two-physical-device Android gate passed speaker playback, encrypted chat, and process-death retry."
