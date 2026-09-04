#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

jq -e -f "$ROOT/scripts/ios-device-is-unlocked.jq" <<'JSON' >/dev/null
{"result":{"passcodeRequired":false,"unlockedSinceBoot":true}}
JSON

if jq -e -f "$ROOT/scripts/ios-device-is-unlocked.jq" <<'JSON' >/dev/null
{"result":{"passcodeRequired":true,"unlockedSinceBoot":true}}
JSON
then
  echo "Lock parser accepted a passcode-locked device." >&2
  exit 1
fi

if jq -e -f "$ROOT/scripts/ios-device-is-unlocked.jq" <<'JSON' >/dev/null
{"result":{"passcodeRequired":false,"unlockedSinceBoot":false}}
JSON
then
  echo "Lock parser accepted a device that has not been unlocked since boot." >&2
  exit 1
fi

echo "iOS physical-device lock parser: ok"
