#!/usr/bin/env bash
# Remove ephemeral Apple provisioning and signing material after physical tests.
set -u

if [[ -n "${PTT_IOS_PROFILE_ID:-}" ]]; then
  node "$(cd "$(dirname "$0")/.." && pwd)/scripts/app-store-connect-profile.mjs" \
    delete "$PTT_IOS_PROFILE_ID" || true
fi
if [[ -n "${PTT_CI_PROFILE_PATH:-}" ]]; then
  rm -f "$PTT_CI_PROFILE_PATH"
fi
if [[ -n "${PTT_CI_KEYCHAIN:-}" ]]; then
  security delete-keychain "$PTT_CI_KEYCHAIN" || true
fi
security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db"
if [[ -n "${PTT_IOS_SIGNING_DIR:-}" ]]; then
  case "$PTT_IOS_SIGNING_DIR" in
    "$RUNNER_TEMP"/ptt-physical-signing-*) rm -rf -- "$PTT_IOS_SIGNING_DIR" ;;
    *) echo "Refusing to remove unexpected signing directory: $PTT_IOS_SIGNING_DIR" >&2 ;;
  esac
fi
