#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-pr}"
case "$PROFILE" in
  pr|nightly|weekly|browser|release|release-aggregate|adversarial) ;;
  *) echo "Usage: $0 {pr|nightly|weekly|browser|release|release-aggregate|adversarial}" >&2; exit 64 ;;
esac

PROMPTFOO_ROOT="$ROOT/qa/promptfoo"
RESULT_DIR="${PTT_PROMPTFOO_RESULT_DIR:-$ROOT/artifacts/promptfoo/$(git -C "$ROOT" rev-parse HEAD)/$PROFILE}"
mkdir -p "$RESULT_DIR"

export PROMPTFOO_DISABLE_TELEMETRY=1
export PROMPTFOO_DISABLE_REDTEAM_REMOTE_GENERATION=true
export PROMPTFOO_CONFIG_DIR="$PROMPTFOO_ROOT"

if [[ ! -x "$PROMPTFOO_ROOT/node_modules/.bin/promptfoo" ]]; then
  npm ci --prefix "$PROMPTFOO_ROOT" --ignore-scripts --no-audit --prefer-offline
fi
if ! node -e 'const Database=require(process.argv[1]); const db=new Database(":memory:"); db.close()' \
  "$PROMPTFOO_ROOT/node_modules/better-sqlite3" >/dev/null 2>&1; then
  npm rebuild --prefix "$PROMPTFOO_ROOT" better-sqlite3
fi
if [[ "$PROFILE" == browser || "$PROFILE" == nightly || "$PROFILE" == weekly ]]; then
  "$PROMPTFOO_ROOT/node_modules/.bin/playwright" install chromium
fi

"$PROMPTFOO_ROOT/node_modules/.bin/promptfoo" validate config \
  --config "$PROMPTFOO_ROOT/suites/$PROFILE.yaml"

args=(
  eval
  --config "$PROMPTFOO_ROOT/suites/$PROFILE.yaml"
  --no-cache
  --output "$RESULT_DIR/results.json"
  --output "$RESULT_DIR/results.html"
)
if [[ -n "${PTT_PROMPTFOO_FILTER_PATTERN:-}" ]]; then
  args+=(--filter-pattern "$PTT_PROMPTFOO_FILTER_PATTERN")
fi
"$PROMPTFOO_ROOT/node_modules/.bin/promptfoo" "${args[@]}"

test -s "$RESULT_DIR/results.json"
test -s "$RESULT_DIR/results.html"
printf 'Promptfoo %s evidence: %s\n' "$PROFILE" "$RESULT_DIR"
