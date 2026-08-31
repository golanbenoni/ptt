#!/usr/bin/env bash
# Run the product's encrypted voice/chat probes on two dedicated physical Apple devices.
set -euo pipefail

: "${PTT_IOS_DEVICE_1:?PTT_IOS_DEVICE_1 is required}"
: "${PTT_IOS_DEVICE_2:?PTT_IOS_DEVICE_2 is required}"
: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"
: "${PTT_E2E_ACI:?PTT_E2E_ACI is required}"
: "${PTT_E2E_SENDER_MAILBOX:?PTT_E2E_SENDER_MAILBOX is required}"
: "${PTT_E2E_RECEIVER_MAILBOX:?PTT_E2E_RECEIVER_MAILBOX is required}"
: "${PTT_E2E_SENDER_TOKEN:?PTT_E2E_SENDER_TOKEN is required}"
: "${PTT_E2E_RECEIVER_TOKEN:?PTT_E2E_RECEIVER_TOKEN is required}"
: "${PTT_E2E_SENDER_IDENTITY_FIXTURE:?PTT_E2E_SENDER_IDENTITY_FIXTURE is required}"
: "${PTT_E2E_RECEIVER_IDENTITY_FIXTURE:?PTT_E2E_RECEIVER_IDENTITY_FIXTURE is required}"

BUNDLE_ID="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
WORK_DIR="$(mktemp -d -t ptt-ios-physical.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in xcrun jq openssl ruby uuidgen; do
  command -v "$command" >/dev/null || {
    echo "Missing physical-test dependency: $command" >&2
    exit 1
  }
done

if [[ "$PTT_IOS_DEVICE_1" == "$PTT_IOS_DEVICE_2" ]]; then
  echo "Physical voice validation requires two different Apple devices." >&2
  exit 1
fi
if [[ ! "$TRANSMISSIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_E2E_TRANSMISSIONS must be a positive integer." >&2
  exit 1
fi

require_debug_app() {
  local device="$1"
  local report
  report="$WORK_DIR/apps-$(uuidgen).json"
  if ! xcrun devicectl device info apps --device "$device" --bundle-id "$BUNDLE_ID" \
    --json-output "$report" >/dev/null 2>&1; then
    echo "Apple device $device is offline, locked, untrusted, or unavailable." >&2
    return 1
  fi
  ruby -rjson -e '
    result = JSON.parse(File.read(ARGV.fetch(0))).fetch("result", {})
    apps = result["apps"] || result["applications"] || []
    wanted = ARGV.fetch(1)
    abort "missing app" unless apps.any? do |app|
      app["bundleIdentifier"] == wanted || app["bundleID"] == wanted
    end
  ' "$report" "$BUNDLE_ID" >/dev/null 2>&1 || {
    echo "Dedicated debug app $BUNDLE_ID is not installed on Apple device $device." >&2
    return 1
  }
}

decode_fixture() {
  local encoded="$1"
  local output="$2"
  printf '%s' "$encoded" | openssl base64 -d -A -out "$output"
  ruby -rjson -e '
    fixture = JSON.parse(File.read(ARGV.fetch(0)))
    abort "invalid identity fixture" unless fixture.fetch("identityKeyPair").length >= 80
    abort "invalid registration ID" unless (1..0x3fff).cover?(fixture.fetch("registrationId"))
  ' "$output"
}

install_fixture() {
  local device="$1"
  local fixture="$2"
  xcrun devicectl device copy to --device "$device" --source "$fixture" \
    --destination Documents/ptt-e2e-identity.json --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" >/dev/null
}

read_marker() {
  local device="$1"
  local name="$2"
  local destination
  destination="$WORK_DIR/marker-$(uuidgen)"
  mkdir -p "$destination"
  if ! xcrun devicectl device copy from --device "$device" \
    --source "Documents/ptt-e2e-$name.txt" --destination "$destination" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" >/dev/null 2>&1; then
    return 0
  fi
  local marker
  marker="$(find "$destination" -type f -print -quit)"
  [[ -n "$marker" ]] && tr -d '\r\n' < "$marker"
}

launch_role() {
  local device="$1"
  local role="$2"
  local device_id="$3"
  local mailbox="$4"
  local token="$5"
  local chat_run="$6"
  shift 6
  local environment
  environment="$(jq -cn \
    --arg token "$token" \
    --arg aci "$PTT_E2E_ACI" \
    --arg mailbox "$mailbox" \
    --arg device "$device_id" \
    --arg run "$chat_run" \
    '{PTT_E2E_ACCESS_TOKEN:$token,PTT_E2E_ACI:$aci,PTT_E2E_MAILBOX:$mailbox,PTT_E2E_DEVICE:$device,PTT_E2E_CHAT_RUN:$run}')"
  local arguments=(--ptt-server "$PTT_E2E_SERVER" "--ptt-e2e-$role")
  if [[ "$role" == sender ]]; then arguments+=(--ptt-synthetic-mic); fi
  arguments+=("$@")
  if ! xcrun devicectl device process launch --device "$device" --terminate-existing \
    --environment-variables "$environment" "$BUNDLE_ID" "${arguments[@]}" >/dev/null 2>&1; then
    echo "Could not launch the $role automation app on Apple device $device." >&2
    return 1
  fi
}

run_process_restart_delivery() {
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  echo "Starting Apple receiver for process-death delivery gate"
  launch_role "$PTT_IOS_DEVICE_2" receiver 2 "$PTT_E2E_RECEIVER_MAILBOX" \
    "$PTT_E2E_RECEIVER_TOKEN" "$run" --ptt-e2e-restart-receiver --ptt-e2e-skip-voice
  echo "Queueing Apple message behind an injected delivery interruption"
  launch_role "$PTT_IOS_DEVICE_1" sender 1 "$PTT_E2E_SENDER_MAILBOX" \
    "$PTT_E2E_SENDER_TOKEN" "$run" --ptt-e2e-queue-before-crash --ptt-e2e-skip-voice
  for _ in {1..90}; do
    local state count
    state="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)"
    count="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-count)"
    [[ "$state" == fail:* ]] && { echo "Apple process-death queue failed: $state" >&2; return 1; }
    [[ "$state" == queued && "$count" == 1 ]] && break
    sleep 1
  done
  if [[ "$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)" != queued ]]; then
    echo "Apple message was not durably queued before process termination." >&2
    return 1
  fi

  echo "Terminating and relaunching Apple sender to prove durable retry"
  launch_role "$PTT_IOS_DEVICE_1" sender 1 "$PTT_E2E_SENDER_MAILBOX" \
    "$PTT_E2E_SENDER_TOKEN" "$run" --ptt-e2e-resume-after-crash --ptt-e2e-skip-voice
  for _ in {1..150}; do
    local sender_state receiver_state receiver_count
    sender_state="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)"
    receiver_state="$(read_marker "$PTT_IOS_DEVICE_2" chat-restart-receiver-state)"
    receiver_count="$(read_marker "$PTT_IOS_DEVICE_2" chat-restart-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ]]; then
      echo "Apple process-death retry failed: sender=$sender_state receiver=$receiver_state" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$receiver_state" == pass && "$receiver_count" == 1 ]]; then
      echo "Apple process-death gate passed: encrypted outbox retried after relaunch"
      return 0
    fi
    sleep 1
  done
  echo "Apple process-death retry timed out." >&2
  return 1
}

wait_until_ready() {
  local label="$1"
  local device="$2"
  local state=""
  for _ in {1..90}; do
    state="$(read_marker "$device" receiver-state)"
    [[ "$state" == ready ]] && return 0
    if [[ "$state" == fail:* ]]; then
      echo "$label receiver setup failed: $state" >&2
      return 1
    fi
    sleep 1
  done
  echo "$label receiver did not become native-PTT ready within 90 seconds (last state: $state)." >&2
  return 1
}

run_direction() {
  local label="$1"
  local sender_device="$2"
  local sender_id="$3"
  local sender_mailbox="$4"
  local sender_token="$5"
  local receiver_device="$6"
  local receiver_id="$7"
  local receiver_mailbox="$8"
  local receiver_token="$9"
  local chat_run
  chat_run="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  echo "Starting $label receiver through Apple's native Push to Talk path"
  launch_role "$receiver_device" receiver "$receiver_id" "$receiver_mailbox" "$receiver_token" "$chat_run"
  wait_until_ready "$label" "$receiver_device"
  echo "Starting $label sender with deterministic encrypted speech"
  launch_role "$sender_device" sender "$sender_id" "$sender_mailbox" "$sender_token" "$chat_run"

  local sender_state="" receiver_state="" sender_count="" receiver_count=""
  local chat_sender_state="" chat_receiver_state="" chat_sender_count="" chat_receiver_count=""
  for attempt in {1..180}; do
    sender_state="$(read_marker "$sender_device" sender-state)"
    receiver_state="$(read_marker "$receiver_device" receiver-state)"
    sender_count="$(read_marker "$sender_device" sender-count)"
    receiver_count="$(read_marker "$receiver_device" receiver-count)"
    chat_sender_state="$(read_marker "$sender_device" chat-sender-state)"
    chat_receiver_state="$(read_marker "$receiver_device" chat-receiver-state)"
    chat_sender_count="$(read_marker "$sender_device" chat-sender-count)"
    chat_receiver_count="$(read_marker "$receiver_device" chat-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ||
          "$chat_sender_state" == fail:* || "$chat_receiver_state" == fail:* ]]; then
      printf '%s failed: voice sender=%s/%s receiver=%s/%s chat sender=%s/%s receiver=%s/%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" \
        "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$sender_count" == "$TRANSMISSIONS" &&
          "$receiver_state" == pass && "$receiver_count" == "$TRANSMISSIONS" &&
          "$chat_sender_state" == pass && "$chat_sender_count" == 14 &&
          "$chat_receiver_state" == pass && "$chat_receiver_count" == 14 ]]; then
      echo "$label passed $TRANSMISSIONS native encrypted PTT transmissions and the encrypted chat matrix"
      return 0
    fi
    if (( attempt % 15 == 0 )); then
      printf 'Waiting %s: voice sender=%s/%s receiver=%s/%s; chat sender=%s/%s receiver=%s/%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" \
        "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count"
    fi
    sleep 1
  done
  echo "$label timed out before the native playback-completion markers reached parity." >&2
  return 1
}

require_debug_app "$PTT_IOS_DEVICE_1"
require_debug_app "$PTT_IOS_DEVICE_2"
decode_fixture "$PTT_E2E_SENDER_IDENTITY_FIXTURE" "$WORK_DIR/device-1.json"
decode_fixture "$PTT_E2E_RECEIVER_IDENTITY_FIXTURE" "$WORK_DIR/device-2.json"
install_fixture "$PTT_IOS_DEVICE_1" "$WORK_DIR/device-1.json"
install_fixture "$PTT_IOS_DEVICE_2" "$WORK_DIR/device-2.json"

run_direction device-1-to-device-2 \
  "$PTT_IOS_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" \
  "$PTT_IOS_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN"
run_direction device-2-to-device-1 \
  "$PTT_IOS_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" \
  "$PTT_IOS_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN"
run_process_restart_delivery

echo "Two-physical-device Apple gate passed speaker playback, encrypted chat, and process-death retry."
