#!/usr/bin/env bash
# Exercise native codec plus real microphone/playback routes on one physical Android device.
# This is useful diagnostic evidence, not the two-device or four-device release gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
APK="${PTT_ANDROID_AUTOMATION_APK:-$ROOT/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
PACKAGE="app.ptt.talk.debug"
ACTIVITY="$PACKAGE/app.ptt.audio.NativeCodecTestActivity"
SERIAL="${PTT_ANDROID_DEVICE:-}"

cleanup() {
  if [[ -n "$SERIAL" ]]; then
    "$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
test -f "$APK" || { echo "Android debug APK was not found: $APK" >&2; exit 1; }
if [[ -z "$SERIAL" ]]; then
  SERIAL="$($ADB devices | awk '$1 !~ /^emulator-/ && $2 == "device" { print $1; exit }')"
fi
[[ -n "$SERIAL" ]] || { echo "No authorized physical Android device is connected." >&2; exit 1; }
[[ "$($ADB -s "$SERIAL" get-state 2>/dev/null || true)" == device ]] || {
  echo "Android device $SERIAL is offline, unauthorized, or unavailable." >&2
  exit 1
}
[[ "$($ADB -s "$SERIAL" shell getprop ro.kernel.qemu | tr -d '\r[:space:]')" != 1 ]] || {
  echo "The single-device hardware diagnostic refuses Android emulators." >&2
  exit 1
}

"$ROOT/scripts/verify-android-custom-permission.sh" "$APK"
release_was_installed=0
if "$ADB" -s "$SERIAL" shell pm path app.ptt.talk >/dev/null 2>&1; then
  release_was_installed=1
fi

"$ADB" -s "$SERIAL" install -r -t "$APK" >/dev/null
"$ADB" -s "$SERIAL" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO >/dev/null
"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE"
"$ADB" -s "$SERIAL" shell am start -n "$ACTIVITY" >/dev/null

result=""
for _ in {1..30}; do
  result="$("$ADB" -s "$SERIAL" logcat -d -s PTT_NATIVE_TEST:I '*:S' 2>/dev/null |
    sed -n 's/.*PTT_NATIVE_TEST: //p' | tail -n 1)"
  [[ -n "$result" ]] && break
  sleep 1
done

if [[ "$result" != PASS\ * ]]; then
  [[ -n "$result" ]] || result="no terminal result"
  echo "Single-device Android diagnostic failed: $result" >&2
  "$ADB" -s "$SERIAL" logcat -d --pid="$($ADB -s "$SERIAL" shell pidof "$PACKAGE" | tr -d '\r')" | tail -n 120 >&2 || true
  exit 1
fi
if [[ "$release_was_installed" == 1 ]] && ! "$ADB" -s "$SERIAL" shell pm path app.ptt.talk >/dev/null 2>&1; then
  echo "The diagnostic install displaced the Google Play application." >&2
  exit 1
fi

manufacturer="$($ADB -s "$SERIAL" shell getprop ro.product.manufacturer | tr -d '\r')"
model="$($ADB -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
api="$($ADB -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
echo "Single-device Android diagnostic passed on $manufacturer $model (API $api): ${result#PASS }"
