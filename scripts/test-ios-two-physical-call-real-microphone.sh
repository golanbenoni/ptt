#!/usr/bin/env bash
# Prove one physical iOS microphone-to-remote-render direction without replacing
# capture samples. Run again with the device identifiers swapped for the reverse
# direction required by the release gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STIMULUS="${PTT_CALL_MICROPHONE_STIMULUS:-$ROOT/scripts/play-call-microphone-fixture.sh}"

test -x "$STIMULUS" || {
  echo "PTT_CALL_MICROPHONE_STIMULUS must name an executable stimulus program." >&2
  exit 1
}

export PTT_CALL_DIAGNOSTIC_AUDIO=1
export PTT_CALL_REQUIRE_REAL_MIC_AUDIO=1
export PTT_CALL_ACTIVE_HOOK="$STIMULUS"
export PTT_CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-20000}"

exec "$ROOT/scripts/test-ios-two-physical-calls.sh"
