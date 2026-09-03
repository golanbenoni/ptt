#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift scripts/generate-app-icons.swift
swift store/android/make-feature.swift
swift website/make-og.swift
node scripts/sync-release-artwork.mjs
node scripts/verify-store-readiness.mjs --update

echo "Refreshed current app, store, website, and social artwork."
