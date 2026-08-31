#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-firebase-client-config.sh"

valid_env=(
  PTT_FIREBASE_APPLICATION_ID=1:123456789012:android:0123456789abcdef
  PTT_FIREBASE_API_KEY=AIza01234567890123456789012345678901234
  PTT_FIREBASE_PROJECT_ID=ptt-talk-prod
  PTT_FIREBASE_SENDER_ID=123456789012
)
env "${valid_env[@]}" "$VALIDATOR" >/dev/null

for invalid in \
  PTT_FIREBASE_APPLICATION_ID=1:999999999999:android:0123456789abcdef \
  PTT_FIREBASE_API_KEY=invalid \
  PTT_FIREBASE_PROJECT_ID=INVALID_PROJECT \
  PTT_FIREBASE_SENDER_ID=not-numeric
do
  candidate=("${valid_env[@]}")
  candidate+=("$invalid")
  if env "${candidate[@]}" "$VALIDATOR" >/dev/null 2>&1; then
    echo "Firebase validator accepted invalid fixture: ${invalid%%=*}" >&2
    exit 1
  fi
done

echo "Firebase client configuration fail-closed fixtures passed"
