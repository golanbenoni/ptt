#!/usr/bin/env bash
# Prove iOS system-channel restoration and Android's mandatory post-boot rearm.
set -euo pipefail

RESTORATION_SCOPE="${PTT_PHYSICAL_RESTORATION_SCOPE:-all}"
case "$RESTORATION_SCOPE" in
  all|ios|android) ;;
  *)
    echo "PTT_PHYSICAL_RESTORATION_SCOPE must be all, ios, or android." >&2
    exit 2
    ;;
esac
if [[ "$RESTORATION_SCOPE" == all || "$RESTORATION_SCOPE" == ios ]]; then
  : "${PTT_IOS_DEVICE_1:?PTT_IOS_DEVICE_1 is required}"
  : "${PTT_IOS_DEVICE_2:?PTT_IOS_DEVICE_2 is required}"
fi
if [[ "$RESTORATION_SCOPE" == all || "$RESTORATION_SCOPE" == android ]]; then
  : "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
  : "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
fi

ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
ANDROID_PACKAGE="${PTT_ANDROID_AUTOMATION_PACKAGE:-app.ptt.talk.debug}"
ANDROID_ACTIVITY="$ANDROID_PACKAGE/app.ptt.talk.TalkActivity"
IOS_BUNDLE_ID="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
WORK_DIR="$(mktemp -d -t ptt-reboot-restoration.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
for command in xcrun ruby uuidgen; do
  command -v "$command" >/dev/null || { echo "Missing reboot-test dependency: $command" >&2; exit 1; }
done

android_pref() {
  local serial="$1"
  "$ADB" -s "$serial" exec-out run-as "$ANDROID_PACKAGE" \
    cat shared_prefs/ptt-session-lifecycle-v1.xml 2>/dev/null || true
}

android_armed() {
  android_pref "$1" | grep -Eq '<boolean name="armed" value="true"'
}

wait_android_boot() {
  local serial="$1"
  for _ in {1..180}; do
    if [[ "$($ADB -s "$serial" get-state 2>/dev/null || true)" == device ]] &&
       [[ "$($ADB -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
      "$ADB" -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
  echo "Android device $serial did not complete reboot within 180 seconds." >&2
  return 1
}

tap_android_rearm() {
  local serial="$1"
  "$ADB" -s "$serial" shell am start -n "$ANDROID_ACTIVITY" >/dev/null
  local xml="$WORK_DIR/window-$serial.xml"
  local center=""
  for _ in {1..30}; do
    "$ADB" -s "$serial" shell uiautomator dump /sdcard/ptt-window.xml >/dev/null 2>&1 || true
    "$ADB" -s "$serial" exec-out cat /sdcard/ptt-window.xml > "$xml" 2>/dev/null || true
    center="$(ruby -rrexml/document -e '
      document = REXML::Document.new(File.read(ARGV.fetch(0)))
      REXML::XPath.each(document, "//node") do |node|
        next unless [node.attributes["text"], node.attributes["content-desc"]].include?("Stay connected")
        bounds = node.attributes["bounds"].to_s.scan(/\d+/).map(&:to_i)
        if bounds.length == 4
          puts "#{(bounds[0] + bounds[2]) / 2} #{(bounds[1] + bounds[3]) / 2}"
          exit
        end
      end
    ' "$xml" 2>/dev/null || true)"
    [[ -n "$center" ]] && break
    sleep 1
  done
  if [[ -z "$center" ]]; then
    echo "Android device $serial did not expose the Stay connected control after reboot." >&2
    return 1
  fi
  read -r x y <<<"$center"
  "$ADB" -s "$serial" shell input tap "$x" "$y"
  for _ in {1..30}; do
    android_armed "$serial" && return 0
    sleep 1
  done
  echo "Android device $serial did not rearm after the required foreground tap." >&2
  return 1
}

test_android_reboot() {
  local serial="$1"
  if ! android_armed "$serial"; then
    echo "Android device $serial was not armed before reboot; the lifecycle precondition failed." >&2
    return 1
  fi
  echo "Rebooting Android device $serial"
  "$ADB" -s "$serial" reboot
  wait_android_boot "$serial"
  for _ in {1..45}; do
    if android_pref "$serial" | grep -Eq '<boolean name="armed" value="false"'; then
      break
    fi
    sleep 1
  done
  if android_armed "$serial" ||
     ! android_pref "$serial" | grep -Eq '<boolean name="armed" value="false"'; then
    echo "Android device $serial remained armed after reboot." >&2
    return 1
  fi
  local running_services
  running_services="$("$ADB" -s "$serial" shell dumpsys activity services "$ANDROID_PACKAGE")"
  if grep -q 'PttSessionService' <<<"$running_services"; then
    echo "Android device $serial restarted microphone-capable PTT work without a user gesture." >&2
    return 1
  fi
  tap_android_rearm "$serial"
  echo "Android device $serial required and accepted a foreground rearm gesture"
}

ios_write_pending_marker() {
  local device="$1"
  local pending="$WORK_DIR/restoration-pending.txt"
  printf '%s' pending > "$pending"
  xcrun devicectl device copy to --device "$device" --source "$pending" \
    --destination Documents/ptt-e2e-system-restoration-state.txt \
    --domain-type appDataContainer --domain-identifier "$IOS_BUNDLE_ID" >/dev/null
}

ios_read_marker() {
  local device="$1"
  local destination
  destination="$WORK_DIR/ios-marker-$(uuidgen)"
  mkdir -p "$destination"
  if ! xcrun devicectl device copy from --device "$device" \
    --source Documents/ptt-e2e-system-restoration-state.txt --destination "$destination" \
    --domain-type appDataContainer --domain-identifier "$IOS_BUNDLE_ID" >/dev/null 2>&1; then
    return 0
  fi
  local marker
  marker="$(find "$destination" -type f -print -quit)"
  [[ -n "$marker" ]] && tr -d '\r\n' < "$marker"
}

test_ios_restoration() {
  local device="$1"
  ios_write_pending_marker "$device"
  echo "Userspace-rebooting Apple device $device"
  xcrun devicectl device reboot --device "$device" --style userspace \
    --wait-for-device --timeout 180 >/dev/null
  xcrun devicectl device process launch --device "$device" --terminate-existing \
    "$IOS_BUNDLE_ID" >/dev/null 2>&1 || {
      echo "Apple device $device did not relaunch after userspace reboot." >&2
      return 1
    }
  local state=""
  for _ in {1..120}; do
    state="$(ios_read_marker "$device")"
    [[ "$state" == pass ]] && {
      echo "Apple device $device restored its system Push to Talk channel"
      return 0
    }
    sleep 1
  done
  echo "Apple device $device did not receive a system Push to Talk restoration callback (last state: $state)." >&2
  return 1
}

if [[ "$RESTORATION_SCOPE" == all || "$RESTORATION_SCOPE" == android ]]; then
  test_android_reboot "$PTT_ANDROID_DEVICE_1"
  test_android_reboot "$PTT_ANDROID_DEVICE_2"
fi
if [[ "$RESTORATION_SCOPE" == all || "$RESTORATION_SCOPE" == ios ]]; then
  test_ios_restoration "$PTT_IOS_DEVICE_1"
  test_ios_restoration "$PTT_IOS_DEVICE_2"
fi

case "$RESTORATION_SCOPE" in
  all) echo "Physical reboot gate passed Android gesture rearming and iOS system-channel restoration." ;;
  ios) echo "Physical restoration gate passed iOS system-channel restoration on both devices." ;;
  android) echo "Physical reboot gate passed Android gesture rearming on both devices." ;;
esac
