#!/usr/bin/env bash
# Build a Play-uploadable AAB without storing signing secrets in the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/java21-env.sh"

PRIVATE_ENV="${PTT_RELEASE_ENV:-$HOME/.ptt_release/android.env}"
if [[ -f "$PRIVATE_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$PRIVATE_ENV"
fi

export PTT_UPLOAD_STORE_FILE="${PTT_UPLOAD_STORE_FILE:-$HOME/.ptt_release/ptt-upload.jks}"
export PTT_UPLOAD_KEY_ALIAS="${PTT_UPLOAD_KEY_ALIAS:-ptt-upload}"

if [[ -z "${PTT_UPLOAD_STORE_PASSWORD:-}" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "set PTT_UPLOAD_STORE_PASSWORD or create $PRIVATE_ENV" >&2
    exit 1
  fi
  PTT_UPLOAD_STORE_PASSWORD="$(
    security find-generic-password \
      -a "$USER" \
      -s app.ptt.talk.upload-keystore \
      -w
  )"
  export PTT_UPLOAD_STORE_PASSWORD
fi

export PTT_UPLOAD_KEY_PASSWORD="${PTT_UPLOAD_KEY_PASSWORD:-$PTT_UPLOAD_STORE_PASSWORD}"

test -f "$PTT_UPLOAD_STORE_FILE"
cd "$ROOT"
./gradlew --no-daemon :talkandroid:lintRelease :talkandroid:bundleRelease

AAB="$ROOT/android/talk/build/outputs/bundle/release/talkandroid-release.aab"
test -f "$AAB"
jarsigner -verify "$AAB" >/dev/null
(
  cd "$(dirname "$AAB")"
  shasum -a 256 "$(basename "$AAB")" > "$(basename "$AAB").sha256"
)
echo "$AAB"
echo "$AAB.sha256"
