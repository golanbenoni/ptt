#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
SIMULATOR_ID="${PTT_IOS_SIMULATOR_ID:-}"
CREATED_SIMULATOR=0

if [[ ! -d "$APP_PATH" ]]; then
  echo "iOS simulator app not found: $APP_PATH" >&2
  exit 1
fi

cleanup() {
  if [[ "$CREATED_SIMULATOR" == "1" && -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices booted --json | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    device = devices.find { |item| item["state"] == "Booted" && item["isAvailable"] != false }
    puts device["udid"] if device
  ')"
fi

if [[ -z "$SIMULATOR_ID" ]]; then
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
  SIMULATOR_ID="$(xcrun simctl create "PTT automated app probe" "$device_type" "$runtime")"
  CREATED_SIMULATOR=1
  xcrun simctl boot "$SIMULATOR_ID"
fi

xcrun simctl bootstatus "$SIMULATOR_ID" -b
open -gj -a Simulator >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
xcrun simctl privacy "$SIMULATOR_ID" grant microphone app.ptt.talk

run_probe() {
  local argument="$1"
  local success_marker="$2"
  local failure_marker="$3"
  local launch_output process_id line attempt
  launch_output="$(xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" app.ptt.talk "$argument")"
  process_id="${launch_output##*: }"
  for attempt in {1..20}; do
    line="$(xcrun simctl spawn "$SIMULATOR_ID" log show --last 1m --style compact \
      --predicate "processIdentifier == $process_id AND eventMessage CONTAINS 'PTT_'" 2>/dev/null | tail -1)"
    if [[ "$line" == *"$success_marker"* ]]; then
      printf '%s\n' "$line"
      return
    fi
    if [[ "$line" == *"$failure_marker"* ]]; then
      printf '%s\n' "$line" >&2
      return 1
    fi
    sleep 1
  done
  echo "$success_marker timed out" >&2
  return 1
}

run_probe --ptt-ui-state-probe PTT_UI_STATE_PROBE_PASS PTT_UI_STATE_PROBE_FAIL
run_probe --ptt-audio-probe PTT_AUDIO_PROBE_PASS PTT_AUDIO_PROBE_FAIL
echo "iOS simulator interaction and physical playback probes passed"
