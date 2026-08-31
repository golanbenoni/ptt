#!/usr/bin/env bash
# Prove Android/iOS wire, crypto, chat, and speaker playback parity on real devices.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
: "${PTT_IOS_DEVICE_1:?PTT_IOS_DEVICE_1 is required}"
: "${PTT_IOS_DEVICE_2:?PTT_IOS_DEVICE_2 is required}"
: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"
: "${PTT_E2E_ACI:?PTT_E2E_ACI is required}"
: "${PTT_E2E_CHANNEL_ID:?PTT_E2E_CHANNEL_ID is required}"
: "${PTT_E2E_SENDER_MAILBOX:?PTT_E2E_SENDER_MAILBOX is required}"
: "${PTT_E2E_RECEIVER_MAILBOX:?PTT_E2E_RECEIVER_MAILBOX is required}"
: "${PTT_E2E_SENDER_TOKEN:?PTT_E2E_SENDER_TOKEN is required}"
: "${PTT_E2E_RECEIVER_TOKEN:?PTT_E2E_RECEIVER_TOKEN is required}"
: "${PTT_E2E_SENDER_IDENTITY_FIXTURE:?PTT_E2E_SENDER_IDENTITY_FIXTURE is required}"
: "${PTT_E2E_RECEIVER_IDENTITY_FIXTURE:?PTT_E2E_RECEIVER_IDENTITY_FIXTURE is required}"

ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_PACKAGE="${PTT_ANDROID_AUTOMATION_PACKAGE:-app.ptt.talk.debug}"
ANDROID_ACTIVITY="$ANDROID_PACKAGE/app.ptt.talk.PhysicalE2EActivity"
IOS_BUNDLE_ID="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
MAX_FLOOR_LATENCY_MS="${PTT_E2E_MAX_FLOOR_LATENCY_MS:-150}"
MAX_READY_LATENCY_MS="${PTT_E2E_MAX_READY_LATENCY_MS:-400}"
WORK_DIR="$(mktemp -d -t ptt-cross-platform-physical.XXXXXX)"
TOUCHED_ANDROID_DEVICES=()

cleanup() {
  for serial in "${TOUCHED_ANDROID_DEVICES[@]}"; do
    "$ADB" -s "$serial" shell svc wifi enable >/dev/null 2>&1 || true
    wake_android "$serial" || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in jq openssl ruby uuidgen xcrun; do
  command -v "$command" >/dev/null || {
    echo "Missing cross-platform test dependency: $command" >&2
    exit 1
  }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
if ! [[ "$TRANSMISSIONS" =~ ^[1-9][0-9]*$ ]]; then
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

require_android_device() {
  local serial="$1"
  [[ "$($ADB -s "$serial" get-state 2>/dev/null || true)" == device ]] || {
    echo "Android device $serial is offline, unauthorized, or unavailable." >&2
    return 1
  }
  "$ADB" -s "$serial" shell pm path "$ANDROID_PACKAGE" >/dev/null 2>&1 || {
    echo "Dedicated debug app $ANDROID_PACKAGE is not installed on Android device $serial." >&2
    return 1
  }
}

require_ios_device() {
  local device="$1"
  local report
  report="$WORK_DIR/ios-apps-$(uuidgen).json"
  xcrun devicectl device info apps --device "$device" --bundle-id "$IOS_BUNDLE_ID" \
    --json-output "$report" >/dev/null 2>&1 || {
      echo "Apple device $device is offline, locked, untrusted, or unavailable." >&2
      return 1
    }
  ruby -rjson -e '
    result = JSON.parse(File.read(ARGV.fetch(0))).fetch("result", {})
    apps = result["apps"] || result["applications"] || []
    wanted = ARGV.fetch(1)
    abort "missing app" unless apps.any? do |app|
      app["bundleIdentifier"] == wanted || app["bundleID"] == wanted
    end
  ' "$report" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || {
    echo "Dedicated debug app $IOS_BUNDLE_ID is not installed on Apple device $device." >&2
    return 1
  }
}

android_copy_private_file() {
  local serial="$1"
  local source="$2"
  local name="$3"
  local remote
  remote="/data/local/tmp/ptt-${name}-$(uuidgen)"
  "$ADB" -s "$serial" push "$source" "$remote" >/dev/null
  "$ADB" -s "$serial" shell run-as "$ANDROID_PACKAGE" mkdir -p files
  "$ADB" -s "$serial" shell run-as "$ANDROID_PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$serial" shell rm "$remote"
}

ios_install_fixture() {
  local device="$1"
  local fixture="$2"
  xcrun devicectl device copy to --device "$device" --source "$fixture" \
    --destination Documents/ptt-e2e-identity.json --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" >/dev/null
}

android_prepare_role() {
  local serial="$1"
  local fixture="$2"
  local role="$3"
  local device_id="$4"
  local mailbox="$5"
  local token="$6"
  local run="$7"
  local config="$WORK_DIR/android-$serial-$role.json"
  jq -cn \
    --arg role "$role" --arg server "$PTT_E2E_SERVER" --arg aci "$PTT_E2E_ACI" \
    --arg channel "$PTT_E2E_CHANNEL_ID" --arg mailbox "$mailbox" --arg token "$token" \
    --arg run "$run" --argjson device "$device_id" --argjson transmissions "$TRANSMISSIONS" \
    '{role:$role,serverUrl:$server,aci:$aci,channelId:$channel,mailboxId:$mailbox,accessToken:$token,deviceId:$device,run:$run,transmissions:$transmissions}' \
    > "$config"
  android_copy_private_file "$serial" "$fixture" ptt-e2e-identity.json
  android_copy_private_file "$serial" "$config" ptt-e2e-config.json
}

launch_android_role() {
  local serial="$1"
  "$ADB" -s "$serial" shell am force-stop "$ANDROID_PACKAGE"
  "$ADB" -s "$serial" shell am start -n "$ANDROID_ACTIVITY" >/dev/null
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

prepare_android_receiver_lifecycle() {
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

launch_ios_role() {
  local device="$1"
  local role="$2"
  local device_id="$3"
  local mailbox="$4"
  local token="$5"
  local run="$6"
  local environment
  environment="$(jq -cn \
    --arg token "$token" --arg aci "$PTT_E2E_ACI" --arg mailbox "$mailbox" \
    --arg device "$device_id" --arg run "$run" \
    '{PTT_E2E_ACCESS_TOKEN:$token,PTT_E2E_ACI:$aci,PTT_E2E_MAILBOX:$mailbox,PTT_E2E_DEVICE:$device,PTT_E2E_CHAT_RUN:$run}')"
  local arguments=(--ptt-server "$PTT_E2E_SERVER" "--ptt-e2e-$role")
  if [[ "$role" == sender ]]; then arguments+=(--ptt-synthetic-mic); fi
  xcrun devicectl device process launch --device "$device" --terminate-existing \
    --environment-variables "$environment" "$IOS_BUNDLE_ID" "${arguments[@]}" >/dev/null 2>&1 || {
      echo "Could not launch the $role automation app on Apple device $device." >&2
      return 1
    }
}

read_android_marker() {
  local serial="$1"
  local name="$2"
  "$ADB" -s "$serial" exec-out run-as "$ANDROID_PACKAGE" \
    cat "files/ptt-e2e-$name.txt" 2>/dev/null | tr -d '\r\n' || true
}

read_ios_marker() {
  local device="$1"
  local name="$2"
  local destination
  destination="$WORK_DIR/ios-marker-$(uuidgen)"
  mkdir -p "$destination"
  if ! xcrun devicectl device copy from --device "$device" \
    --source "Documents/ptt-e2e-$name.txt" --destination "$destination" \
    --domain-type appDataContainer --domain-identifier "$IOS_BUNDLE_ID" >/dev/null 2>&1; then
    return 0
  fi
  local marker
  marker="$(find "$destination" -type f -print -quit)"
  [[ -n "$marker" ]] && tr -d '\r\n' < "$marker"
}

read_marker() {
  local platform="$1"
  local device="$2"
  local name="$3"
  if [[ "$platform" == android ]]; then
    read_android_marker "$device" "$name"
  else
    read_ios_marker "$device" "$name"
  fi
}

launch_role() {
  local platform="$1"
  local device="$2"
  local fixture="$3"
  local role="$4"
  local device_id="$5"
  local mailbox="$6"
  local token="$7"
  local run="$8"
  if [[ "$platform" == android ]]; then
    android_prepare_role "$device" "$fixture" "$role" "$device_id" "$mailbox" "$token" "$run"
    launch_android_role "$device"
  else
    ios_install_fixture "$device" "$fixture"
    launch_ios_role "$device" "$role" "$device_id" "$mailbox" "$token" "$run"
  fi
}

wait_receiver_ready() {
  local label="$1"
  local platform="$2"
  local device="$3"
  local state=""
  for _ in {1..90}; do
    state="$(read_marker "$platform" "$device" receiver-state)"
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
  local sender_platform="$2" sender_device="$3" sender_id="$4" sender_mailbox="$5" sender_token="$6" sender_fixture="$7"
  local receiver_platform="$8" receiver_device="$9" receiver_id="${10}" receiver_mailbox="${11}" receiver_token="${12}" receiver_fixture="${13}"
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  echo "Starting $label receiver"
  launch_role "$receiver_platform" "$receiver_device" "$receiver_fixture" receiver \
    "$receiver_id" "$receiver_mailbox" "$receiver_token" "$run"
  wait_receiver_ready "$label" "$receiver_platform" "$receiver_device"
  if [[ "$receiver_platform" == android ]]; then
    prepare_android_receiver_lifecycle "$label" "$receiver_device"
  fi
  echo "Starting $label sender with deterministic encrypted speech"
  launch_role "$sender_platform" "$sender_device" "$sender_fixture" sender \
    "$sender_id" "$sender_mailbox" "$sender_token" "$run"

  local sender_state="" receiver_state="" sender_count="" receiver_count=""
  local chat_sender_state="" chat_receiver_state="" chat_sender_count="" chat_receiver_count=""
  for attempt in {1..180}; do
    sender_state="$(read_marker "$sender_platform" "$sender_device" sender-state)"
    receiver_state="$(read_marker "$receiver_platform" "$receiver_device" receiver-state)"
    sender_count="$(read_marker "$sender_platform" "$sender_device" sender-count)"
    receiver_count="$(read_marker "$receiver_platform" "$receiver_device" receiver-count)"
    chat_sender_state="$(read_marker "$sender_platform" "$sender_device" chat-sender-state)"
    chat_receiver_state="$(read_marker "$receiver_platform" "$receiver_device" chat-receiver-state)"
    chat_sender_count="$(read_marker "$sender_platform" "$sender_device" chat-sender-count)"
    chat_receiver_count="$(read_marker "$receiver_platform" "$receiver_device" chat-receiver-count)"
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
        "$(read_marker "$sender_platform" "$sender_device" floor-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_FLOOR_LATENCY_MS"
      "$ROOT/scripts/assert-latency-samples.sh" "$label communication ready" \
        "$(read_marker "$sender_platform" "$sender_device" ready-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_READY_LATENCY_MS"
      echo "$label passed $TRANSMISSIONS encrypted PTT transmissions and the 14-operation encrypted chat matrix"
      if [[ "$receiver_platform" == android ]]; then wake_android "$receiver_device"; fi
      return 0
    fi
    if (( attempt % 15 == 0 )); then
      echo "Waiting $label: voice sender=$sender_state/$sender_count receiver=$receiver_state/$receiver_count; chat sender=$chat_sender_state/$chat_sender_count receiver=$chat_receiver_state/$chat_receiver_count"
    fi
    sleep 1
  done
  echo "$label timed out before authenticated speaker-playback completion." >&2
  return 1
}

decode_fixture "$PTT_E2E_SENDER_IDENTITY_FIXTURE" "$WORK_DIR/device-1.json"
decode_fixture "$PTT_E2E_RECEIVER_IDENTITY_FIXTURE" "$WORK_DIR/device-2.json"
require_android_device "$PTT_ANDROID_DEVICE_1"
require_android_device "$PTT_ANDROID_DEVICE_2"
require_ios_device "$PTT_IOS_DEVICE_1"
require_ios_device "$PTT_IOS_DEVICE_2"

run_direction android-to-ios \
  android "$PTT_ANDROID_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$WORK_DIR/device-1.json" \
  ios "$PTT_IOS_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" "$WORK_DIR/device-2.json"
run_direction ios-to-android \
  ios "$PTT_IOS_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" "$WORK_DIR/device-1.json" \
  android "$PTT_ANDROID_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" "$WORK_DIR/device-2.json"

echo "Cross-platform physical PTT gate passed in both platform directions after native speaker-playback completion."
