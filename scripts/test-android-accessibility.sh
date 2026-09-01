#!/usr/bin/env bash
# Exercise production Android onboarding, Talk, and Chat surfaces with large text in both themes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${PTT_ANDROID_ACCESSIBILITY_APK:-$ROOT_DIR/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
PACKAGE="app.ptt.talk.debug"
FIXTURE_ACTIVITY="$PACKAGE/app.ptt.talk.AccessibilityFixtureActivity"
WORK_DIR="$(mktemp -d -t ptt-android-accessibility.XXXXXX)"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$SDK_ROOT" && -d /opt/homebrew/share/android-commandlinetools ]]; then
  SDK_ROOT=/opt/homebrew/share/android-commandlinetools
fi
ADB="${ADB:-${SDK_ROOT:+$SDK_ROOT/platform-tools/adb}}"
EMULATOR="${EMULATOR:-${SDK_ROOT:+$SDK_ROOT/emulator/emulator}}"
AVD="${PTT_ANDROID_ACCESSIBILITY_AVD:-fireos_stock_api30}"
SERIAL="${PTT_ANDROID_ACCESSIBILITY_DEVICE:-}"
EMULATOR_PID=""
SERVER_PID=""

cleanup() {
  local status=$?
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$EMULATOR_PID" && -n "$SERIAL" ]]; then "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; fi
  if [[ $status -eq 0 && "${PTT_KEEP_ACCESSIBILITY_ARTIFACTS:-0}" != 1 ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "Android accessibility artifacts retained at $WORK_DIR" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

for command in curl node ruby; do
  command -v "$command" >/dev/null || { echo "Missing Android accessibility dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -x "$EMULATOR" || { echo "Android emulator was not found at $EMULATOR" >&2; exit 1; }
test -f "$APK" || { echo "Android debug APK was not found at $APK" >&2; exit 1; }

node "$ROOT_DIR/scripts/android-accessibility-server.mjs" >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..30}; do
  curl -fsS http://127.0.0.1:39183/healthz >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS http://127.0.0.1:39183/healthz >/dev/null

if [[ -z "$SERIAL" ]]; then
  SERIAL="$($ADB devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1; exit }')"
fi
if [[ -z "$SERIAL" ]]; then
  SERIAL=emulator-5584
  "$EMULATOR" -avd "$AVD" -port 5584 -no-window -no-audio -no-boot-anim \
    -no-snapshot-load -no-snapshot-save -gpu swiftshader_indirect >"$WORK_DIR/emulator.log" 2>&1 &
  EMULATOR_PID=$!
fi

for _ in {1..180}; do
  if [[ "$($ADB -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then break; fi
  sleep 1
done
[[ "$($ADB -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || {
  echo "Android emulator $SERIAL did not finish booting." >&2
  exit 1
}

$ADB -s "$SERIAL" install -r -t "$APK" >/dev/null
$ADB -s "$SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true

density="$($ADB -s "$SERIAL" shell wm density | awk '/Override density:/ { value=$3 } /Physical density:/ && value == "" { value=$3 } END { print value }' | tr -d '\r')"
[[ "$density" =~ ^[0-9]+$ ]] || { echo "Could not determine emulator density." >&2; exit 1; }

dump_window() {
  local output="$1"
  $ADB -s "$SERIAL" shell uiautomator dump /sdcard/ptt-accessibility.xml >/dev/null
  $ADB -s "$SERIAL" exec-out cat /sdcard/ptt-accessibility.xml >"$output"
}

assert_accessible_targets() {
  local xml="$1"
  ruby -rrexml/document -e '
    density = ARGV.shift.to_f
    minimum = 44.0 * density / 160.0
    document = REXML::Document.new(File.read(ARGV.shift))
    viewport = REXML::XPath.first(document, "//node[@scrollable=\"true\"]") || REXML::XPath.first(document, "//node")
    viewport_bounds = viewport.attributes["bounds"].to_s.scan(/\d+/).map(&:to_i)
    failures = []
    REXML::XPath.each(document, "//node") do |node|
      attributes = node.attributes
      interactive = attributes["clickable"] == "true" || attributes["long-clickable"] == "true"
      next unless interactive
      label = [attributes["text"], attributes["content-desc"]].join.strip
      failures << "unlabelled interactive #{attributes["class"]} #{attributes["bounds"]}" if label.empty?
      bounds = attributes["bounds"].to_s.scan(/\d+/).map(&:to_i)
      next unless bounds.length == 4
      # UiAutomator clips a partially visible scrolling child to the viewport.
      # Validate it once a later dump has scrolled the complete target onscreen.
      next if viewport_bounds.length == 4 && (bounds[1] <= viewport_bounds[1] || bounds[3] >= viewport_bounds[3])
      width = bounds[2] - bounds[0]
      height = bounds[3] - bounds[1]
      if width + 0.5 < minimum || height + 0.5 < minimum
        failures << "undersized #{label.inspect}: #{width}x#{height}px, minimum #{minimum.round(1)}px"
      end
    end
    abort failures.join("\n") unless failures.empty?
  ' "$density" "$xml"
}

find_text() {
  local phrase="$1"
  local prefix="$2"
  local xml="$WORK_DIR/$prefix.xml"
  for attempt in {0..8}; do
    dump_window "$xml"
    assert_accessible_targets "$xml"
    if ruby -rrexml/document -e '
      phrase = ARGV.shift
      document = REXML::Document.new(File.read(ARGV.shift))
      found = REXML::XPath.match(document, "//node").any? do |node|
        node.attributes["text"].to_s.include?(phrase) || node.attributes["content-desc"].to_s.include?(phrase)
      end
      exit(found ? 0 : 1)
    ' "$phrase" "$xml"; then return 0; fi
    $ADB -s "$SERIAL" shell input swipe 540 1500 540 450 250 >/dev/null
    sleep 0.3
  done
  echo "Expected Android accessibility text was not reachable: $phrase" >&2
  return 1
}

tap_text() {
  local phrase="$1"
  local prefix="$2"
  local xml="$WORK_DIR/$prefix-tap.xml"
  local coordinates
  for attempt in {0..8}; do
    dump_window "$xml"
    assert_accessible_targets "$xml"
    coordinates="$(ruby -rrexml/document -e '
      phrase = ARGV.shift
      document = REXML::Document.new(File.read(ARGV.shift))
      node = REXML::XPath.match(document, "//node").find do |candidate|
        candidate.attributes["text"].to_s.include?(phrase) ||
          candidate.attributes["content-desc"].to_s.include?(phrase)
      end
      exit 1 unless node
      bounds = node.attributes.fetch("bounds").to_s.scan(/\d+/).map(&:to_i)
      exit 1 unless bounds.length == 4
      puts "#{(bounds[0] + bounds[2]) / 2} #{(bounds[1] + bounds[3]) / 2}"
    ' "$phrase" "$xml" 2>/dev/null || true)"
    if [[ -n "$coordinates" ]]; then
      read -r x y <<<"$coordinates"
      $ADB -s "$SERIAL" shell input tap "$x" "$y"
      sleep 0.5
      return 0
    fi
    $ADB -s "$SERIAL" shell input swipe 540 1500 540 450 250 >/dev/null
    sleep 0.3
  done
  echo "Android onboarding control was not reachable: $phrase" >&2
  return 1
}

run_surface() {
  local mode="$1"
  local font_scale="$2"
  local appearance="$3"
  local screen="$4"
  shift 4
  local prefix="$mode-$screen"
  local xml="$WORK_DIR/$prefix.xml"

  $ADB -s "$SERIAL" shell settings put system font_scale "$font_scale"
  $ADB -s "$SERIAL" shell cmd uimode night "$appearance" >/dev/null
  $ADB -s "$SERIAL" shell am force-stop "$PACKAGE"
  $ADB -s "$SERIAL" shell am start -W -n "$FIXTURE_ACTIVITY" --es screen "$screen" >/dev/null
  sleep 1.5
  dump_window "$xml"
  assert_accessible_targets "$xml"
  $ADB -s "$SERIAL" exec-out screencap -p >"$WORK_DIR/$prefix.png"
  local phrase
  for phrase in "$@"; do find_text "$phrase" "$prefix"; done
  echo "Android accessibility surface passed: $prefix"
}

for appearance in no yes; do
  theme=$([[ "$appearance" == yes ]] && echo dark || echo light)
  run_surface "$theme-standard" 1.0 "$appearance" onboarding \
    "Private voice for your team" "Open email" "Link a second device"
  run_surface "$theme-standard" 1.0 "$appearance" talk \
    "PTT Talk" "Device Test" "Hold to talk" "Encrypted chat" "Account, devices & privacy"
  run_surface "$theme-standard" 1.0 "$appearance" chat \
    "Encrypted chat" "Send message" "File" "Video" "Voice" "Back to Talk"
  run_surface "$theme-maximum" 2.0 "$appearance" onboarding \
    "Private voice for your team" "Open email" "Link a second device"
  run_surface "$theme-maximum" 2.0 "$appearance" talk \
    "PTT Talk" "Device Test" "Hold to talk" "Encrypted chat" "Account, devices & privacy"
  run_surface "$theme-maximum" 2.0 "$appearance" chat \
    "Encrypted chat" "Send message" "File" "Video" "Voice" "Back to Talk"
done

$ADB -s "$SERIAL" shell settings put system font_scale 1.0
$ADB -s "$SERIAL" shell cmd uimode night no >/dev/null
$ADB -s "$SERIAL" shell am force-stop "$PACKAGE"
$ADB -s "$SERIAL" shell am start -W -n "$FIXTURE_ACTIVITY" --es screen onboarding >/dev/null
sleep 1.5

tap_text "Enter invite manually" onboarding-manual
find_text "Enter invitation details" onboarding-manual
find_text "Send sign-in email" onboarding-manual
tap_text "Back" onboarding-manual-back
find_text "Open your team invite" onboarding-manual-back

tap_text "Link a second device" onboarding-link
find_text "Link this device" onboarding-link
find_text "Continue with the manual codes" onboarding-link
tap_text "Back to enrollment" onboarding-link-back
find_text "Open your team invite" onboarding-link-back

tap_text "Recover an account" onboarding-recovery
find_text "Recover your account" onboarding-recovery
find_text "Send recovery email" onboarding-recovery
tap_text "Back" onboarding-recovery-back
find_text "Open your team invite" onboarding-recovery-back

echo "Android onboarding navigation passed manual invitation, second-device linking, and recovery routes."

echo "Android onboarding, Talk, and Chat accessibility passed in light/dark at standard and maximum font scales."
