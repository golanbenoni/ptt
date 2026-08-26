#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYED=0

case "${1:-}" in
  "") ;;
  --deployed) DEPLOYED=1 ;;
  *)
    echo "usage: $0 [--deployed]" >&2
    exit 2
    ;;
esac

echo "[1/3] Native Opus, PLC, jitter, and audio-energy tests"
cargo test --manifest-path "$ROOT/native/Cargo.toml" --locked -p audio-engine

echo "[2/3] Swift non-silent Opus/SFrame media path"
(
  cd "$ROOT/ios/PttTalk"
  swift test --filter 'productionVoicePipeline|releasingWhileSecuritySetup|systemManagedPlayback|playoutMaintains'
)

echo "[3/3] Two-device Cloudflare floor and media relay"
npm test --prefix "$ROOT/cloudflare"

if [[ "$DEPLOYED" == 1 ]]; then
  echo "[deployed] Authenticated two-device media tunnel"
  npm run test:deployed-media --prefix "$ROOT/cloudflare"
else
  echo "Local voice gate passed. Use --deployed with dedicated device tokens to test the deployed Worker."
fi
