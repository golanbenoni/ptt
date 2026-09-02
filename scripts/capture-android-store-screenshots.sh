#!/usr/bin/env bash
# Capture release-facing screenshots from the real debug activity fixture.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${PTT_ANDROID_STORE_APK:-$ROOT_DIR/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
OUTPUT_DIR="${PTT_ANDROID_STORE_OUTPUT:-$ROOT_DIR/store/screenshots/android}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}}"
ADB="${ADB:-$SDK_ROOT/platform-tools/adb}"
EMULATOR="${EMULATOR:-$SDK_ROOT/emulator/emulator}"
AVD="${PTT_ANDROID_STORE_AVD:-fireos_stock_api30}"
SERIAL="${PTT_ANDROID_STORE_DEVICE:-}"
PORT="${PTT_ANDROID_STORE_PORT:-5584}"
WORK_DIR="$(mktemp -d -t ptt-android-store.XXXXXX)"
SERVER_PID=""
EMULATOR_PID=""

cleanup() {
  local status=$?
  [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" >/dev/null 2>&1 || true
  if [[ -n "$EMULATOR_PID" && -n "$SERIAL" ]]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || kill "$EMULATOR_PID" >/dev/null 2>&1 || true
  elif [[ "${PTT_ANDROID_STORE_STOP_REUSED_EMULATOR:-0}" == 1 && "$SERIAL" == emulator-* ]]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT

for command in curl ffmpeg node ruby; do
  command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -x "$EMULATOR" || { echo "Android emulator was not found at $EMULATOR" >&2; exit 1; }
test -f "$APK" || {
  echo "Android debug APK not found: $APK" >&2
  echo "Build :talkandroid:assembleDebug first, or set PTT_ANDROID_STORE_APK." >&2
  exit 1
}

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
  SERIAL="emulator-$PORT"
  "$EMULATOR" -avd "$AVD" -port "$PORT" -no-window -no-audio -no-boot-anim \
    -no-snapshot-load -no-snapshot-save -gpu host >"$WORK_DIR/emulator.log" 2>&1 &
  EMULATOR_PID=$!
fi

for _ in {1..180}; do
  [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 1
done
[[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || {
  echo "Android emulator $SERIAL did not finish booting." >&2
  exit 1
}

"$ADB" -s "$SERIAL" install -r -t "$APK" >/dev/null
"$ADB" -s "$SERIAL" shell settings put system font_scale 1.0
"$ADB" -s "$SERIAL" shell cmd uimode night no >/dev/null
"$ADB" -s "$SERIAL" shell input keyevent 224 >/dev/null 2>&1 || true
if [[ "$SERIAL" == emulator-* ]]; then
  # Google Play recommends 9:16 phone screenshots and rejects images whose
  # longest edge is more than twice the shortest edge.
  "$ADB" -s "$SERIAL" shell wm size 1080x1920
  "$ADB" -s "$SERIAL" shell wm density 360
fi
mkdir -p "$OUTPUT_DIR"

wait_for_text() {
  local phrase="$1"
  local xml="$WORK_DIR/wait.xml"
  for _ in {1..30}; do
    "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/ptt-store-wait.xml >/dev/null 2>&1 || true
    "$ADB" -s "$SERIAL" pull /sdcard/ptt-store-wait.xml "$xml" >/dev/null 2>&1 || true
    if [[ -s "$xml" ]] && grep -Fq "$phrase" "$xml"; then
      return 0
    fi
    sleep 0.4
  done
  echo "Android store capture did not render: $phrase" >&2
  return 1
}

launch_surface() {
  local screen="$1"
  local expected_text="$2"
  "$ADB" -s "$SERIAL" shell am force-stop app.ptt.talk.debug
  "$ADB" -s "$SERIAL" shell am start -W \
    -n app.ptt.talk.debug/app.ptt.talk.AccessibilityFixtureActivity \
    --es screen "$screen" >/dev/null
  wait_for_text "$expected_text"
  sleep 0.5
}

capture() {
  local remote="$1"
  local output="$2"
  local destination="$OUTPUT_DIR/$output"
  local flattened="$WORK_DIR/$output"
  "$ADB" -s "$SERIAL" shell screencap -p "/sdcard/$remote"
  "$ADB" -s "$SERIAL" pull "/sdcard/$remote" "$destination" >/dev/null
  test -s "$destination" || { echo "Empty Android screenshot: $output" >&2; exit 1; }
  ffmpeg -v error -y -i "$destination" -vf format=rgb24 -frames:v 1 "$flattened"
  mv "$flattened" "$destination"
}

tap_text() {
  local phrase="$1"
  local xml="$WORK_DIR/tap.xml"
  local attempt
  for attempt in {1..9}; do
    "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/ptt-store-tap.xml >/dev/null
    "$ADB" -s "$SERIAL" pull /sdcard/ptt-store-tap.xml "$xml" >/dev/null
    local coordinates
    coordinates="$(ruby -rrexml/document -e '
      phrase = ARGV.fetch(0)
      document = REXML::Document.new(File.read(ARGV.fetch(1)))
      node = REXML::XPath.match(document, "//node").find do |candidate|
        candidate.attributes["text"].to_s.include?(phrase) ||
          candidate.attributes["content-desc"].to_s.include?(phrase)
      end
      exit 1 unless node
      bounds = node.attributes.fetch("bounds").to_s.scan(/\d+/).map(&:to_i)
      puts "#{(bounds[0] + bounds[2]) / 2} #{(bounds[1] + bounds[3]) / 2}"
    ' "$phrase" "$xml" 2>/dev/null || true)"
    if [[ -n "$coordinates" ]]; then
      read -r x y <<<"$coordinates"
      "$ADB" -s "$SERIAL" shell input tap "$x" "$y"
      return 0
    fi
    "$ADB" -s "$SERIAL" shell input swipe 540 1700 540 360 300 >/dev/null
    sleep 0.4
  done
  echo "Android store capture could not find: $phrase" >&2
  return 1
}

launch_surface talk "Hold to talk"
capture ptt-store-talk.png phone-release.png
tap_text "Settings"
wait_for_text "Settings"
sleep 0.5
capture ptt-store-security.png phone-security.png

launch_surface chat "End-to-end encrypted"
"$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/ptt-store-chat.xml >/dev/null
"$ADB" -s "$SERIAL" pull /sdcard/ptt-store-chat.xml "$WORK_DIR/chat.xml" >/dev/null
sleep 3
capture ptt-store-chat.png phone-chat.png

launch_surface onboarding "Open your team invite"
capture ptt-store-onboarding.png phone-onboarding.png

echo "Captured current Android Talk, Chat, onboarding, and security screenshots in $OUTPUT_DIR"
