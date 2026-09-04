#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

test "$(node "$ROOT/scripts/run-with-timeout.mjs" 2 /bin/sh -c 'printf bounded-ok')" = bounded-ok

started=$SECONDS
set +e
node "$ROOT/scripts/run-with-timeout.mjs" 1 /bin/sh -c 'sleep 30' >/dev/null 2>&1
status=$?
set -e
elapsed=$((SECONDS - started))

test "$status" -eq 124
test "$elapsed" -lt 5
echo "Bounded command runner passed success and timeout probes."
