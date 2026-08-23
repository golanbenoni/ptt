#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="53320c81e5549baa3fdf35d457c4e887e222baa37c88ce291957d73a3736c28b"
DESCRIPTOR="$(mktemp -t ptt-protocol-v1).pb"
trap 'rm -f "$DESCRIPTOR"' EXIT

protoc \
  -I "$ROOT/proto" \
  --include_imports \
  --descriptor_set_out="$DESCRIPTOR" \
  "$ROOT/proto/control.proto" \
  "$ROOT/proto/media.proto"

ACTUAL="$(shasum -a 256 "$DESCRIPTOR" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "protocol v1 descriptor changed" >&2
  echo "expected: $EXPECTED" >&2
  echo "actual:   $ACTUAL" >&2
  echo "Review compatibility, update cross-platform golden vectors, then update EXPECTED." >&2
  exit 1
fi

echo "protocol v1 contract ok: $ACTUAL"
