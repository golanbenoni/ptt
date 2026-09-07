#!/usr/bin/env bash
# Run bidirectional Android/iOS product diagnostics with one physical device per platform.
# This deliberately cannot satisfy the four-distinct-device release gate.
set -euo pipefail

: "${PTT_ANDROID_DEVICE:?PTT_ANDROID_DEVICE is required}"
: "${PTT_IOS_DEVICE:?PTT_IOS_DEVICE is required}"
: "${PTT_ACOUSTIC_INPUT:?PTT_ACOUSTIC_INPUT is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PTT_ANDROID_DEVICE_1="$PTT_ANDROID_DEVICE"
export PTT_ANDROID_DEVICE_2="$PTT_ANDROID_DEVICE"
export PTT_IOS_DEVICE_1="$PTT_IOS_DEVICE"
export PTT_IOS_DEVICE_2="$PTT_IOS_DEVICE"
export PTT_ACOUSTIC_EXPECTED_DIRECTIONS=2

echo "Running reduced one-Android/one-Apple diagnostic; this is not release-gate evidence."
"$ROOT/scripts/record-physical-acoustic.sh" "$ROOT/scripts/test-cross-platform-physical-voice.sh"
echo "Reduced Android/iOS diagnostic passed encrypted voice, chat, playback, and external acoustic checks in both directions."
