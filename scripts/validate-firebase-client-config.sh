#!/usr/bin/env bash
set -euo pipefail

: "${PTT_FIREBASE_APPLICATION_ID:?PTT_FIREBASE_APPLICATION_ID is required for release push wake}"
: "${PTT_FIREBASE_API_KEY:?PTT_FIREBASE_API_KEY is required for release push wake}"
: "${PTT_FIREBASE_PROJECT_ID:?PTT_FIREBASE_PROJECT_ID is required for release push wake}"
: "${PTT_FIREBASE_SENDER_ID:?PTT_FIREBASE_SENDER_ID is required for release push wake}"

if [[ ! "$PTT_FIREBASE_APPLICATION_ID" =~ ^1:${PTT_FIREBASE_SENDER_ID}:android:[0-9a-f]+$ ||
      ! "$PTT_FIREBASE_API_KEY" =~ ^AIza[0-9A-Za-z_-]{35}$ ||
      ! "$PTT_FIREBASE_SENDER_ID" =~ ^[0-9]+$ ||
      ! "$PTT_FIREBASE_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  echo "Firebase release identifiers are missing, malformed, or inconsistent." >&2
  exit 1
fi

echo "Firebase client configuration is structurally valid."
