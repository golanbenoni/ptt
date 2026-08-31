#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
TRANSMISSIONS=5

: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"
: "${PTT_E2E_ACI:?PTT_E2E_ACI is required}"
: "${PTT_E2E_CHANNEL_ID:?PTT_E2E_CHANNEL_ID is required}"
: "${PTT_E2E_SENDER_MAILBOX:?PTT_E2E_SENDER_MAILBOX is required}"
: "${PTT_E2E_RECEIVER_MAILBOX:?PTT_E2E_RECEIVER_MAILBOX is required}"
: "${PTT_E2E_SENDER_TOKEN:?PTT_E2E_SENDER_TOKEN is required}"
: "${PTT_E2E_RECEIVER_TOKEN:?PTT_E2E_RECEIVER_TOKEN is required}"
: "${PTT_E2E_SENDER_IDENTITY_FIXTURE:?PTT_E2E_SENDER_IDENTITY_FIXTURE is required}"
: "${PTT_E2E_RECEIVER_IDENTITY_FIXTURE:?PTT_E2E_RECEIVER_IDENTITY_FIXTURE is required}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "iOS simulator app not found: $APP_PATH" >&2
  exit 1
fi

wait_for_boot() {
  local simulator_id="$1"
  xcrun simctl bootstatus "$simulator_id" -b &
  local boot_pid=$!
  for _ in {1..90}; do
    if ! kill -0 "$boot_pid" 2>/dev/null; then
      wait "$boot_pid"
      return
    fi
    sleep 1
  done
  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
  echo "Simulator failed to finish booting within 90 seconds" >&2
  return 1
}

read_app_marker() {
  local container="$1"
  local name="$2"
  local marker="$container/Documents/ptt-e2e-$name.txt"
  [[ -f "$marker" ]] && /bin/cat "$marker" || true
}

dump_app_diagnostics() {
  local simulator_id="$1"
  local label="$2"
  echo "$label privacy-safe PTT diagnostics"
  xcrun simctl spawn "$simulator_id" log show --style compact --last 10m \
    --predicate 'process == "TalkApp" AND eventMessage CONTAINS "PTT_E2E"' 2>/dev/null | tail -400 || true
}

runtime="$(xcrun simctl list runtimes --json | ruby -rjson -e '
  runtimes = JSON.parse(STDIN.read).fetch("runtimes").select do |item|
    item["platform"] == "iOS" && item["isAvailable"] != false
  end
  selected = runtimes.max_by { |item| item.fetch("version", "0").split(".").map(&:to_i) }
  puts selected["identifier"] if selected
')"
device_type="${PTT_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
if [[ -z "$runtime" ]]; then
  echo "No available iOS Simulator runtime was found" >&2
  exit 1
fi

echo "Removing stale PTT E2E simulator fixtures"
while IFS= read -r stale_id; do
  [[ -z "$stale_id" ]] && continue
  xcrun simctl shutdown "$stale_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$stale_id" >/dev/null 2>&1 || true
done < <(xcrun simctl list devices --json | ruby -rjson -e '
  JSON.parse(STDIN.read).fetch("devices").each_value do |devices|
    devices.select { |device| ["PTT E2E sender", "PTT E2E receiver"].include?(device["name"]) }
      .each { |device| puts device["udid"] }
  end
')

sender_id="$(xcrun simctl create "PTT E2E sender" "$device_type" "$runtime")"
receiver_id="$(xcrun simctl create "PTT E2E receiver" "$device_type" "$runtime")"
fixture_dir="$(mktemp -d -t ptt-e2e-identities.XXXXXX)"
cleanup() {
  xcrun simctl shutdown "$sender_id" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$receiver_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$sender_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$receiver_id" >/dev/null 2>&1 || true
  rm -rf "$fixture_dir"
}
trap cleanup EXIT

printf '%s' "$PTT_E2E_SENDER_IDENTITY_FIXTURE" | openssl base64 -d -A -out "$fixture_dir/sender.json"
printf '%s' "$PTT_E2E_RECEIVER_IDENTITY_FIXTURE" | openssl base64 -d -A -out "$fixture_dir/receiver.json"
test -s "$fixture_dir/sender.json"
test -s "$fixture_dir/receiver.json"
for fixture in "$fixture_dir/sender.json" "$fixture_dir/receiver.json"; do
  ruby -rjson -e '
    fixture = JSON.parse(File.read(ARGV.fetch(0)))
    abort "invalid automation identity fixture" unless fixture.fetch("identityKeyPair").length >= 80
    abort "invalid automation registration ID" unless (1..0x3fff).cover?(fixture.fetch("registrationId"))
  ' "$fixture"
done
echo "Automation identity fixtures decoded"
node "$ROOT/cloudflare/test/drain-automation-prekeys.mjs"

echo "Booting two isolated iOS simulators"
xcrun simctl boot "$sender_id"
xcrun simctl boot "$receiver_id"
wait_for_boot "$sender_id"
wait_for_boot "$receiver_id"
echo "Installing signed app into both simulators"
xcrun simctl install "$sender_id" "$APP_PATH"
xcrun simctl install "$receiver_id" "$APP_PATH"
xcrun simctl privacy "$sender_id" grant microphone app.ptt.talk
xcrun simctl privacy "$receiver_id" grant microphone app.ptt.talk
sender_container="$(xcrun simctl get_app_container "$sender_id" app.ptt.talk data)"
receiver_container="$(xcrun simctl get_app_container "$receiver_id" app.ptt.talk data)"
mkdir -p "$sender_container/Documents" "$receiver_container/Documents"
cp "$fixture_dir/sender.json" "$sender_container/Documents/ptt-e2e-identity.json"
cp "$fixture_dir/receiver.json" "$receiver_container/Documents/ptt-e2e-identity.json"

run_direction() {
  local label="$1"
  local active_sender_id="$2"
  local active_sender_device="$3"
  local active_sender_token="$4"
  local active_sender_mailbox="$5"
  local active_sender_container="$6"
  local active_receiver_id="$7"
  local active_receiver_device="$8"
  local active_receiver_token="$9"
  local active_receiver_mailbox="${10}"
  local active_receiver_container="${11}"

  xcrun simctl terminate "$active_sender_id" app.ptt.talk >/dev/null 2>&1 || true
  xcrun simctl terminate "$active_receiver_id" app.ptt.talk >/dev/null 2>&1 || true
  rm -f \
    "$active_sender_container/Documents/ptt-e2e-sender-state.txt" \
    "$active_sender_container/Documents/ptt-e2e-sender-count.txt" \
    "$active_receiver_container/Documents/ptt-e2e-receiver-state.txt" \
    "$active_receiver_container/Documents/ptt-e2e-receiver-count.txt" \
    "$active_sender_container/Documents/ptt-e2e-chat-sender-state.txt" \
    "$active_sender_container/Documents/ptt-e2e-chat-sender-count.txt" \
    "$active_receiver_container/Documents/ptt-e2e-chat-receiver-state.txt" \
    "$active_receiver_container/Documents/ptt-e2e-chat-receiver-count.txt"

  local chat_run
  chat_run="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  echo "Starting $label receiving app instance"
  local receiver_launch
  receiver_launch="$(SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$active_receiver_token" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$active_receiver_mailbox" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="$active_receiver_device" \
  SIMCTL_CHILD_PTT_E2E_CHAT_RUN="$chat_run" \
  xcrun simctl launch --terminate-running-process "$active_receiver_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-receiver)"
  echo "$label receiver launch: $receiver_launch"

  # Do not guess how long enrollment, key publication, and relay setup take.
  # A sender may only start once the opposite product instance reports that its
  # encrypted media path is actually ready.
  local receiver_ready=false
  for _ in {1..45}; do
    local setup_state
    setup_state="$(read_app_marker "$active_receiver_container" receiver-state)"
    if [[ "$setup_state" == "ready" ]]; then
      receiver_ready=true
      break
    fi
    if [[ "$setup_state" == fail:* ]]; then
      echo "$label receiver setup failed: $setup_state" >&2
      return 1
    fi
    sleep 1
  done
  if [[ "$receiver_ready" != true ]]; then
    echo "$label receiver did not become media-ready within 45 seconds" >&2
    return 1
  fi

  echo "Starting $label sending app instance and $TRANSMISSIONS automated holds"
  local sender_launch
  sender_launch="$(SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$active_sender_token" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$active_sender_mailbox" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="$active_sender_device" \
  SIMCTL_CHILD_PTT_E2E_CHAT_RUN="$chat_run" \
  xcrun simctl launch --terminate-running-process "$active_sender_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-sender --ptt-synthetic-mic)"
  echo "$label sender launch: $sender_launch"

  local sender_state=""
  local receiver_state=""
  local sender_count=""
  local receiver_count=""
  local chat_sender_state=""
  local chat_receiver_state=""
  local chat_sender_count=""
  local chat_receiver_count=""
  for attempt in {1..90}; do
    sender_state="$(read_app_marker "$active_sender_container" sender-state)"
    receiver_state="$(read_app_marker "$active_receiver_container" receiver-state)"
    sender_count="$(read_app_marker "$active_sender_container" sender-count)"
    receiver_count="$(read_app_marker "$active_receiver_container" receiver-count)"
    chat_sender_state="$(read_app_marker "$active_sender_container" chat-sender-state)"
    chat_receiver_state="$(read_app_marker "$active_receiver_container" chat-receiver-state)"
    chat_sender_count="$(read_app_marker "$active_sender_container" chat-sender-count)"
    chat_receiver_count="$(read_app_marker "$active_receiver_container" chat-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ||
          "$chat_sender_state" == fail:* || "$chat_receiver_state" == fail:* ]]; then
      local chat_sender_stage
      chat_sender_stage="$(read_app_marker "$active_sender_container" chat-sender-stage)"
      printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" >&2
      printf '%s chat_sender=%s stage=%s chat_sender_count=%s chat_receiver=%s chat_receiver_count=%s\n' \
        "$label" "$chat_sender_state" "$chat_sender_stage" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count" >&2
      dump_app_diagnostics "$active_sender_id" "$label sender"
      dump_app_diagnostics "$active_receiver_id" "$label receiver"
      return 1
    fi
    if [[ "$sender_state" == "pass" && "$sender_count" == "$TRANSMISSIONS" &&
          "$receiver_state" == "pass" && "$receiver_count" == "$TRANSMISSIONS" &&
          "$chat_sender_state" == "pass" && "$chat_sender_count" == "11" &&
          "$chat_receiver_state" == "pass" && "$chat_receiver_count" == "11" ]]; then
      printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count"
      echo "$label passed $TRANSMISSIONS consecutive encrypted app transmissions"
      echo "$label passed encrypted text/file/voice/video, reply, reaction, edit, delete, and receipt delivery"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      printf 'Waiting %s: sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count"
      printf 'Waiting %s chat: sender=%s/%s receiver=%s/%s\n' \
        "$label" "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count"
    fi
    sleep 1
  done

  echo "$label timed out" >&2
  printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
    "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" >&2
  printf '%s chat_sender=%s chat_sender_count=%s chat_receiver=%s chat_receiver_count=%s\n' \
    "$label" "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count" >&2
  dump_app_diagnostics "$active_sender_id" "$label sender"
  dump_app_diagnostics "$active_receiver_id" "$label receiver"
  return 1
}

run_process_restart_delivery() {
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local sender_state_marker="$sender_container/Documents/ptt-e2e-chat-restart-sender-state.txt"
  local sender_count_marker="$sender_container/Documents/ptt-e2e-chat-restart-sender-count.txt"
  local receiver_state_marker="$receiver_container/Documents/ptt-e2e-chat-restart-receiver-state.txt"
  local receiver_count_marker="$receiver_container/Documents/ptt-e2e-chat-restart-receiver-count.txt"
  xcrun simctl terminate "$sender_id" app.ptt.talk >/dev/null 2>&1 || true
  xcrun simctl terminate "$receiver_id" app.ptt.talk >/dev/null 2>&1 || true
  rm -f "$sender_state_marker" "$sender_count_marker" "$receiver_state_marker" "$receiver_count_marker"

  echo "Starting receiver for process-death delivery gate"
  SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_E2E_RECEIVER_TOKEN" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_E2E_RECEIVER_MAILBOX" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="2" \
  SIMCTL_CHILD_PTT_E2E_CHAT_RUN="$run" \
  xcrun simctl launch --terminate-running-process "$receiver_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-receiver \
    --ptt-e2e-restart-receiver --ptt-e2e-skip-voice >/dev/null

  echo "Queueing a message behind an injected delivery interruption"
  SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_E2E_SENDER_TOKEN" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_E2E_SENDER_MAILBOX" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="1" \
  SIMCTL_CHILD_PTT_E2E_CHAT_RUN="$run" \
  xcrun simctl launch --terminate-running-process "$sender_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-sender \
    --ptt-e2e-queue-before-crash --ptt-e2e-skip-voice >/dev/null

  for _ in {1..60}; do
    state="$(read_app_marker "$sender_container" chat-restart-sender-state)"
    count="$(read_app_marker "$sender_container" chat-restart-sender-count)"
    [[ "$state" == fail:* ]] && { echo "Process-death queue gate failed: $state" >&2; return 1; }
    [[ "$state" == "queued" && "$count" == "1" ]] && break
    sleep 1
  done
  if [[ "$(read_app_marker "$sender_container" chat-restart-sender-state)" != "queued" ]]; then
    echo "Message was not durably queued before process termination" >&2
    return 1
  fi

  echo "Terminating sender and relaunching it to prove durable retry"
  xcrun simctl terminate "$sender_id" app.ptt.talk
  SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_E2E_SENDER_TOKEN" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_E2E_SENDER_MAILBOX" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="1" \
  SIMCTL_CHILD_PTT_E2E_CHAT_RUN="$run" \
  xcrun simctl launch "$sender_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-sender \
    --ptt-e2e-resume-after-crash --ptt-e2e-skip-voice >/dev/null

  for _ in {1..120}; do
    sender_state="$(read_app_marker "$sender_container" chat-restart-sender-state)"
    receiver_state="$(read_app_marker "$receiver_container" chat-restart-receiver-state)"
    [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ]] && {
      echo "Process-death retry gate failed: sender=$sender_state receiver=$receiver_state" >&2
      return 1
    }
    if [[ "$sender_state" == "pass" && "$receiver_state" == "pass" &&
          "$(read_app_marker "$receiver_container" chat-restart-receiver-count)" == "1" ]]; then
      echo "Process-death gate passed: durable queue retried after relaunch and decrypted on the peer"
      return 0
    fi
    sleep 1
  done
  echo "Process-death retry gate timed out" >&2
  return 1
}

run_direction \
  "device-1-to-device-2" \
  "$sender_id" 1 "$PTT_E2E_SENDER_TOKEN" "$PTT_E2E_SENDER_MAILBOX" "$sender_container" \
  "$receiver_id" 2 "$PTT_E2E_RECEIVER_TOKEN" "$PTT_E2E_RECEIVER_MAILBOX" "$receiver_container"
run_direction \
  "device-2-to-device-1" \
  "$receiver_id" 2 "$PTT_E2E_RECEIVER_TOKEN" "$PTT_E2E_RECEIVER_MAILBOX" "$receiver_container" \
  "$sender_id" 1 "$PTT_E2E_SENDER_TOKEN" "$PTT_E2E_SENDER_MAILBOX" "$sender_container"
run_process_restart_delivery

echo "iOS two-simulator production gate passed $((TRANSMISSIONS * 2)) voice transmissions, the encrypted chat matrix in both directions, and process-death retry"
