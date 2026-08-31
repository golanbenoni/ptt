#!/usr/bin/env bash
# Audit every primary iOS surface in both appearances and at standard/maximum text sizes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/TalkApp/TalkApp.xcodeproj"
SCHEME="TalkAppAccessibility"
WORK_DIR="$(mktemp -d -t ptt-ios-accessibility.XXXXXX)"
SIMULATOR_ID="${PTT_IOS_SIMULATOR:-}"

cleanup() {
  if [[ "${PTT_KEEP_ACCESSIBILITY_ARTIFACTS:-0}" == 1 ]]; then
    echo "Accessibility artifacts retained at $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

for command in xcodebuild xcrun ruby; do
  command -v "$command" >/dev/null || {
    echo "Missing accessibility-test dependency: $command" >&2
    exit 1
  }
done

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    device = devices.find { |entry| entry.fetch("name", "").include?("iPhone") }
    abort "No available iPhone simulator" unless device
    puts device.fetch("udid")
  ')"
fi

run_mode() {
  local name="$1"
  local content_size="$2"
  local appearance="$3"
  shift 3
  local derived="$WORK_DIR/derived-$name"
  local result="$WORK_DIR/$name.xcresult"
  local log="$WORK_DIR/$name.log"
  local tests=()
  local test
  for test in "$@"; do tests+=("-only-testing:TalkAppUITests/TalkAppAccessibilityTests/$test"); done

  xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl boot "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
  xcrun simctl ui "$SIMULATOR_ID" content_size "$content_size"
  xcrun simctl ui "$SIMULATOR_ID" increase_contrast enabled
  xcrun simctl ui "$SIMULATOR_ID" appearance "$appearance"

  echo "Auditing $name on simulator $SIMULATOR_ID"
  if ! xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$derived" \
    -resultBundlePath "$result" \
    CODE_SIGNING_ALLOWED=NO \
    "${tests[@]}" >"$log" 2>&1; then
    tail -240 "$log" >&2
    echo "$name accessibility audit failed; result: $result" >&2
    exit 1
  fi
  grep -E 'Test Case|TEST SUCCEEDED' "$log" | tail -40
}

run_mode light-standard large light \
  testBrandPaletteMeetsWCAGContrast \
  testPrimarySurfacesAtStandardTextSize
run_mode dark-standard large dark \
  testPrimarySurfacesAtStandardTextSize
run_mode light-maximum accessibility-extra-extra-extra-large light \
  testPrimarySurfacesAtLargestTextSize \
  testCoreTalkControlHasExplicitSemantics
run_mode dark-maximum accessibility-extra-extra-extra-large dark \
  testPrimarySurfacesAtLargestTextSize \
  testCoreTalkControlHasExplicitSemantics

echo "iOS accessibility gate passed in light/dark appearance at standard and maximum text sizes."
