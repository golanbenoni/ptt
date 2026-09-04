#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d -t ptt-ios-marker-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

printf '%s\r\n' \
  '2026-09-04 TalkApp PTT_E2E_MARKER receiver-state=starting' \
  '2026-09-04 TalkApp PTT_E2E_MARKER sender-state=pass' \
  '2026-09-04 TalkApp PTT_E2E_MARKER receiver-state=ready' \
  > "$WORK_DIR/device-console.log"

actual="$(awk -v marker_name=receiver-state \
  -f "$ROOT/scripts/read-ios-console-marker.awk" "$WORK_DIR/device-console.log")"
[[ "$actual" == ready ]] || {
  printf 'Expected normalized latest marker "ready", received %q.\n' "$actual" >&2
  exit 1
}

missing="$(awk -v marker_name=missing \
  -f "$ROOT/scripts/read-ios-console-marker.awk" "$WORK_DIR/device-console.log")"
[[ -z "$missing" ]] || {
  printf 'Expected an absent marker to be empty, received %q.\n' "$missing" >&2
  exit 1
}

echo "iOS console marker parser: ok"
