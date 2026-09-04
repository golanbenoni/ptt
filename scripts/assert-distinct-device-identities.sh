#!/usr/bin/env bash
# Fail closed when multiple transport endpoints resolve to one physical device.
set -euo pipefail

if [[ "${1:-}" == "--self-test" ]]; then
  "$0" "self-test" "synthetic-device-a" "synthetic-device-b" >/dev/null
  if "$0" "expected-failure" "synthetic-device-a" "synthetic-device-a" >/dev/null 2>&1; then
    echo "Device identity gate accepted two aliases for one device." >&2
    exit 1
  fi
  if "$0" "expected-failure" "unknown" "synthetic-device-b" >/dev/null 2>&1; then
    echo "Device identity gate accepted an unavailable identity." >&2
    exit 1
  fi
  echo "Physical device identity self-test passed: aliases and unavailable identities are rejected"
  exit 0
fi

label="${1:?gate label is required}"
first="${2:?first hardware identity is required}"
second="${3:?second hardware identity is required}"

normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

first="$(normalize "$first")"
second="$(normalize "$second")"
for identity in "$first" "$second"; do
  if [[ -z "$identity" || "$identity" == unknown || "$identity" == null ]]; then
    echo "$label: a stable hardware identity is unavailable; refusing to infer two physical devices." >&2
    exit 1
  fi
done
if [[ "$first" == "$second" ]]; then
  echo "$label: both transport endpoints resolve to the same physical device." >&2
  exit 1
fi

echo "$label passed: two distinct physical hardware identities were verified"
