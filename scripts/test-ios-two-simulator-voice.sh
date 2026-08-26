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
    "$active_receiver_container/Documents/ptt-e2e-receiver-count.txt"

  echo "Starting $label receiving app instance"
  local receiver_launch
  receiver_launch="$(SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$active_receiver_token" \
  SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
  SIMCTL_CHILD_PTT_E2E_MAILBOX="$active_receiver_mailbox" \
  SIMCTL_CHILD_PTT_E2E_DEVICE="$active_receiver_device" \
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
  xcrun simctl launch --terminate-running-process "$active_sender_id" app.ptt.talk \
    --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-sender --ptt-synthetic-mic)"
  echo "$label sender launch: $sender_launch"

  local sender_state=""
  local receiver_state=""
  local sender_count=""
  local receiver_count=""
  for attempt in {1..90}; do
    sender_state="$(read_app_marker "$active_sender_container" sender-state)"
    receiver_state="$(read_app_marker "$active_receiver_container" receiver-state)"
    sender_count="$(read_app_marker "$active_sender_container" sender-count)"
    receiver_count="$(read_app_marker "$active_receiver_container" receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ]]; then
      printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" >&2
      return 1
    fi
    if [[ "$sender_state" == "pass" && "$sender_count" == "$TRANSMISSIONS" &&
          "$receiver_state" == "pass" && "$receiver_count" == "$TRANSMISSIONS" ]]; then
      printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count"
      echo "$label passed $TRANSMISSIONS consecutive encrypted app transmissions"
      return 0
    fi
    if (( attempt % 10 == 0 )); then
      printf 'Waiting %s: sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count"
    fi
    sleep 1
  done

  echo "$label timed out" >&2
  printf '%s sender_state=%s sender_count=%s receiver_state=%s receiver_count=%s\n' \
    "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" >&2
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

echo "iOS two-simulator production voice passed $((TRANSMISSIONS * 2)) bidirectional transmissions"
