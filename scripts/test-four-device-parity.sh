#!/usr/bin/env bash
# One release gate for same-platform and cross-platform physical parity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running Apple-to-Apple physical parity"
"$ROOT/scripts/test-ios-two-physical-voice.sh"
echo "Running Android-to-Android physical parity"
"$ROOT/scripts/test-android-two-physical-voice.sh"
echo "Running Android/iOS physical interoperability"
"$ROOT/scripts/test-cross-platform-physical-voice.sh"

echo "Four-device parity gate passed: iOS, Android, and both cross-platform directions."
