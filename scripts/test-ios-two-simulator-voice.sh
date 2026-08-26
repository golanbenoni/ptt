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

if [[ ! -d "$APP_PATH" ]]; then
  echo "iOS simulator app not found: $APP_PATH" >&2
  exit 1
fi

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

export LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$HOME/src/libsignal/swift}"
export LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$HOME/src/libsignal/target/debug}"
PTT_E2E_IDENTITY_EXPORT_DIR="$fixture_dir" swift run \
  --package-path "$ROOT/ios/PttTalk" ProductionVoiceProbe export-identities
node "$ROOT/cloudflare/test/drain-automation-prekeys.mjs"

xcrun simctl boot "$sender_id"
xcrun simctl boot "$receiver_id"
xcrun simctl bootstatus "$sender_id" -b
xcrun simctl bootstatus "$receiver_id" -b
xcrun simctl install "$sender_id" "$APP_PATH"
xcrun simctl install "$receiver_id" "$APP_PATH"
xcrun simctl privacy "$sender_id" grant microphone app.ptt.talk
xcrun simctl privacy "$receiver_id" grant microphone app.ptt.talk
sender_container="$(xcrun simctl get_app_container "$sender_id" app.ptt.talk data)"
receiver_container="$(xcrun simctl get_app_container "$receiver_id" app.ptt.talk data)"
mkdir -p "$sender_container/Documents" "$receiver_container/Documents"
cp "$fixture_dir/sender.json" "$sender_container/Documents/ptt-e2e-identity.json"
cp "$fixture_dir/receiver.json" "$receiver_container/Documents/ptt-e2e-identity.json"

SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_E2E_RECEIVER_TOKEN" \
SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_E2E_RECEIVER_MAILBOX" \
SIMCTL_CHILD_PTT_E2E_DEVICE=2 \
xcrun simctl launch --terminate-running-process "$receiver_id" app.ptt.talk \
  --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-receiver >/dev/null

# Let the receiver publish fresh simulator prekeys before the sender requests
# an authenticated media epoch for it.
sleep 4

SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_E2E_SENDER_TOKEN" \
SIMCTL_CHILD_PTT_E2E_ACI="$PTT_E2E_ACI" \
SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_E2E_SENDER_MAILBOX" \
SIMCTL_CHILD_PTT_E2E_DEVICE=1 \
xcrun simctl launch --terminate-running-process "$sender_id" app.ptt.talk \
  --ptt-server "$PTT_E2E_SERVER" --ptt-e2e-sender --ptt-synthetic-mic >/dev/null

for attempt in {1..60}; do
  sender_log="$(xcrun simctl spawn "$sender_id" log show --last 3m --style compact \
    --predicate "eventMessage CONTAINS 'PTT_E2E_'" 2>/dev/null | tail -1)"
  receiver_log="$(xcrun simctl spawn "$receiver_id" log show --last 3m --style compact \
    --predicate "eventMessage CONTAINS 'PTT_E2E_'" 2>/dev/null | tail -1)"
  if [[ "$sender_log" == *"PTT_E2E_"*"FAIL"* || "$receiver_log" == *"PTT_E2E_"*"FAIL"* ]]; then
    printf '%s\n%s\n' "$sender_log" "$receiver_log" >&2
    exit 1
  fi
  if [[ "$sender_log" == *"PTT_E2E_TRANSMISSIONS_PASS count=$TRANSMISSIONS"* &&
        "$receiver_log" == *"PTT_E2E_PLAYBACK_PASS count=$TRANSMISSIONS"* ]]; then
    printf '%s\n%s\n' "$sender_log" "$receiver_log"
    echo "iOS two-simulator production voice passed $TRANSMISSIONS consecutive transmissions"
    exit 0
  fi
  sleep 1
done

echo "iOS two-simulator production voice timed out" >&2
xcrun simctl spawn "$sender_id" log show --last 3m --style compact \
  --predicate "eventMessage CONTAINS 'PTT_'" 2>/dev/null | tail -80 >&2 || true
xcrun simctl spawn "$receiver_id" log show --last 3m --style compact \
  --predicate "eventMessage CONTAINS 'PTT_'" 2>/dev/null | tail -80 >&2 || true
exit 1
