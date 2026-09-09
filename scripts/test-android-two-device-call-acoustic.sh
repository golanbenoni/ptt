#!/usr/bin/env bash
# Prove that encrypted full-duplex call audio exits a second physical Android device's speaker.
# The caller injects a deterministic fixture only after WebRTC capture; a room microphone must
# hear all five remote bursts and pair them with the caller's local source markers.
set -euo pipefail

: "${PTT_ACOUSTIC_INPUT:?PTT_ACOUSTIC_INPUT is required (AVFoundation input index or exact name)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
ORIGINAL_VOICE_VOLUMES=()

restore_volume() {
  local entry serial volume
  for entry in "${ORIGINAL_VOICE_VOLUMES[@]}"; do
    serial="${entry%%:*}"
    volume="${entry#*:}"
    "$ADB" -s "$serial" shell cmd media_session volume --stream 0 --set "$volume" >/dev/null 2>&1 || true
  done
}
trap restore_volume EXIT INT TERM

for serial in "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}" \
  "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"; do
  report="$($ADB -s "$serial" shell cmd media_session volume --stream 0 --get 2>/dev/null | tr -d '\r')"
  current="$(sed -n 's/.*volume is \([0-9][0-9]*\) in range \[[0-9][0-9]*\.\.\([0-9][0-9]*\)\].*/\1/p' <<<"$report")"
  maximum="$(sed -n 's/.*volume is \([0-9][0-9]*\) in range \[[0-9][0-9]*\.\.\([0-9][0-9]*\)\].*/\2/p' <<<"$report")"
  [[ "$current" =~ ^[0-9]+$ && "$maximum" =~ ^[1-9][0-9]*$ ]] || {
    echo "Could not read Android voice-call volume for acoustic validation on $serial." >&2
    exit 1
  }
  ORIGINAL_VOICE_VOLUMES+=("$serial:$current")
  "$ADB" -s "$serial" shell cmd media_session volume --stream 0 --set "$maximum" >/dev/null
done

export PTT_CALL_SYNTHETIC_AUDIO=1
export PTT_CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-10000}"
export PTT_E2E_TRANSMISSIONS=5
export PTT_ACOUSTIC_EXPECTED_DIRECTIONS=1
export PTT_ACOUSTIC_MAXIMUM_DIRECTIONS=1

"$ROOT/scripts/record-physical-acoustic.sh" "$ROOT/scripts/test-android-two-device-calls.sh"
