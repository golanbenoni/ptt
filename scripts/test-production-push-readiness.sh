#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-production-push-readiness.mjs"

printf '%s' '{"status":"ok","pushReadiness":{"fcmConfigured":true,"apnsConfigured":true}}' | \
  node "$VALIDATOR" >/dev/null

for fixture in \
  '{"status":"ok","pushReadiness":{"fcmConfigured":false,"apnsConfigured":true}}' \
  '{"status":"ok","pushReadiness":{"fcmConfigured":true,"apnsConfigured":false}}' \
  '{"status":"ok"}' \
  '{"status":"not_ready","pushReadiness":{"fcmConfigured":true,"apnsConfigured":true}}' \
  'not-json'
do
  if printf '%s' "$fixture" | node "$VALIDATOR" >/dev/null 2>&1; then
    echo "Push readiness validator accepted an invalid response: $fixture" >&2
    exit 1
  fi
done

echo "Production push readiness fail-closed fixtures passed"
