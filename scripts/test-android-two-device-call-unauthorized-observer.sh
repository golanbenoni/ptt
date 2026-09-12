#!/usr/bin/env bash
# Exercise a known five-burst encrypted product call while a subscriber-only
# LiveKit client with wrong keys proves it cannot render the media.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/ios/PttTalk"

swift build --package-path "$PACKAGE" --product CallCiphertextObserverProbe >/dev/null
export PTT_CALL_LIVEKIT_OBSERVER_BINARY="$(
  swift build --package-path "$PACKAGE" --show-bin-path
)/CallCiphertextObserverProbe"
export PTT_CALL_SYNTHETIC_AUDIO=1
export PTT_CALL_DIAGNOSTIC_AUDIO=1
export PTT_CALL_ACTIVE_HOOK="$ROOT/scripts/run-livekit-unauthorized-observer.sh"
export PTT_CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-20000}"
export PTT_OBSERVER_EXPECTED_TRACKS=2
export PTT_OBSERVER_DURATION_SECONDS="${PTT_OBSERVER_DURATION_SECONDS:-8}"

exec "$ROOT/scripts/test-android-two-device-calls.sh"
