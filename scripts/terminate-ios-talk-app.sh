#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <device-id> [--require-running]" >&2
  exit 2
fi

DEVICE="$1"
REQUIRE_RUNNING="${2:-}"
if [[ -n "$REQUIRE_RUNNING" && "$REQUIRE_RUNNING" != "--require-running" ]]; then
  echo "Unknown option: $REQUIRE_RUNNING" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND_TIMEOUT_SECONDS="${PTT_IOS_DEVICE_COMMAND_TIMEOUT_SECONDS:-8}"
WORK_DIR="$(mktemp -d -t ptt-ios-process-cleanup.XXXXXX)"
REPORT="$WORK_DIR/processes.json"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

bounded() {
  node "$ROOT/scripts/run-with-timeout.mjs" "$COMMAND_TIMEOUT_SECONDS" "$@"
}

bounded xcrun devicectl device info processes --device "$DEVICE" \
  --json-output "$REPORT" >/dev/null

PIDS="$(ruby -rjson -e '
  root = JSON.parse(File.read(ARGV.fetch(0)))
  matches = []
  walk = lambda do |value|
    case value
    when Hash
      pid = value["processIdentifier"] || value["pid"]
      strings = value.values.grep(String)
      if pid && strings.any? { |item|
        item.include?("app.ptt.talk") || item.include?("/TalkApp.app/") ||
          item.include?("/PTT Talk.app/") || item == "PTT Talk" || item == "TalkApp"
      }
        matches << pid
      end
      value.each_value { |child| walk.call(child) }
    when Array
      value.each { |child| walk.call(child) }
    end
  end
  walk.call(root.fetch("result", root))
  puts matches.uniq
' "$REPORT")"

if [[ -z "$PIDS" ]]; then
  if [[ "$REQUIRE_RUNNING" == "--require-running" ]]; then
    echo "PTT Talk is not running on Apple device $DEVICE." >&2
    exit 1
  fi
  exit 0
fi

while IFS= read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || {
    echo "Invalid PTT Talk process identifier returned for $DEVICE." >&2
    exit 1
  }
  bounded xcrun devicectl device process terminate --device "$DEVICE" \
    --pid "$pid" --kill >/dev/null
done <<< "$PIDS"
