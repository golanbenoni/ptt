#!/usr/bin/env bash
# Capture release-facing screenshots from the real debug app fixture.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${PTT_IOS_STORE_APP:-$ROOT_DIR/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
OUTPUT_DIR="${PTT_IOS_STORE_OUTPUT:-$ROOT_DIR/store/screenshots/ios}"
PHONE_SIMULATOR="${PTT_IOS_STORE_PHONE_SIMULATOR:-${PTT_IOS_STORE_SIMULATOR:-}}"
TABLET_SIMULATOR="${PTT_IOS_STORE_TABLET_SIMULATOR:-}"
WORK_DIR="$(mktemp -d -t ptt-ios-store.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in ffmpeg ruby xcrun; do
  command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done

test -d "$APP" || {
  echo "iOS simulator app not found: $APP" >&2
  echo "Build TalkApp for iphonesimulator first, or set PTT_IOS_STORE_APP." >&2
  exit 1
}

if [[ -z "$PHONE_SIMULATOR" ]]; then
  PHONE_SIMULATOR="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    phone = devices.find { |d| d.fetch("deviceTypeIdentifier", "").include?("iPhone-17-Pro-Max") } ||
      devices.find { |d| d.fetch("name", "").include?("Pro Max") }
    abort "No available iPhone Pro Max simulator was found." unless phone
    print phone.fetch("udid")
  ')"
fi
if [[ -z "$TABLET_SIMULATOR" ]]; then
  TABLET_SIMULATOR="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    tablet = devices.find { |d| d.fetch("deviceTypeIdentifier", "").include?("iPad-Pro-13-inch") }
    abort "No available 13-inch iPad Pro simulator was found." unless tablet
    print tablet.fetch("udid")
  ')"
fi
mkdir -p "$OUTPUT_DIR"

capture_device() {
  local simulator="$1"
  local prefix="$2"
  local booted_by_script=0
  if ! xcrun simctl list devices | grep -F "$simulator" | grep -q '(Booted)'; then
    xcrun simctl boot "$simulator"
    booted_by_script=1
  fi
  xcrun simctl bootstatus "$simulator" -b
  xcrun simctl ui "$simulator" appearance light
  xcrun simctl ui "$simulator" content_size medium
  xcrun simctl ui "$simulator" increase_contrast disabled
  xcrun simctl status_bar "$simulator" override \
    --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
  xcrun simctl install "$simulator" "$APP"

  local tab
  for tab in talk chat settings; do
    local output="$OUTPUT_DIR/$prefix-${tab/talk/release}.png"
    local launch_args=(--ptt-screenshot-fixture --ptt-screenshot-tab "$tab")
    if [[ "$tab" == "chat" ]]; then
      launch_args+=(--ptt-screenshot-conversation)
    fi
    xcrun simctl launch --terminate-running-process "$simulator" app.ptt.talk "${launch_args[@]}" >/dev/null
    sleep 2
    xcrun simctl io "$simulator" screenshot "$output" >/dev/null
    local flattened="$WORK_DIR/$prefix-${tab/talk/release}.png"
    ffmpeg -v error -y -i "$output" -vf format=rgb24 -frames:v 1 "$flattened"
    mv "$flattened" "$output"
  done
  if [[ "$booted_by_script" == 1 ]]; then
    xcrun simctl shutdown "$simulator"
  fi
}

capture_device "$PHONE_SIMULATOR" iphone
capture_device "$TABLET_SIMULATOR" ipad

echo "Captured current iPhone Pro Max and 13-inch iPad Talk, Chat, and Settings screenshots in $OUTPUT_DIR"
