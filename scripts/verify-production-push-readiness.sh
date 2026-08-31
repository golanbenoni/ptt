#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"

case "$PTT_E2E_SERVER" in
  https://*) ;;
  *)
    echo "Release blocked: PTT_E2E_SERVER must use HTTPS." >&2
    exit 1
    ;;
esac

health_url="${PTT_E2E_SERVER%/}/healthz"
curl --fail --silent --show-error \
  --connect-timeout 10 --max-time 30 \
  "$health_url" | node "$ROOT/scripts/validate-production-push-readiness.mjs"
