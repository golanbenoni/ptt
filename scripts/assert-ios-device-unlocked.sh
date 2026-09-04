#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "Usage: $0 <CoreDevice identifier>" >&2
  exit 2
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
report="$(mktemp -t ptt-ios-lock-state.XXXXXX)"
trap 'rm -f "$report"' EXIT

xcrun devicectl device info lockState --device "$1" --json-output "$report" >/dev/null
if ! jq -e -f "$ROOT/scripts/ios-device-is-unlocked.jq" "$report" >/dev/null; then
  echo "Apple physical device $1 is locked. Unlock it before dispatching the release gate; the automation app will keep it awake after launch." >&2
  exit 1
fi
