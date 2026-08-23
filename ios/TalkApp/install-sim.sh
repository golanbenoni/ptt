#!/usr/bin/env bash
# Build TalkApp for the booted iOS simulator and install it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
FFI="${LIBSIGNAL_FFI:-$HOME/src/libsignal/target/aarch64-apple-ios-sim/debug}"
if [[ ! -f "$FFI/libsignal_ffi.a" ]]; then
  echo "missing $FFI/libsignal_ffi.a — run: CARGO_BUILD_TARGET=aarch64-apple-ios-sim ~/src/libsignal/swift/build_ffi.sh -d" >&2
  exit 1
fi
DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone 17}"
xcodebuild -project "$ROOT/TalkApp.xcodeproj" -scheme TalkApp \
  -destination "$DEST" \
  -derivedDataPath "$ROOT/.derived" \
  CODE_SIGNING_ALLOWED=NO \
  LIBRARY_SEARCH_PATHS="$FFI" \
  build
APP="$(find "$ROOT/.derived" -name TalkApp.app | head -1)"
test -n "$APP"
xcrun simctl install booted "$APP"
xcrun simctl launch booted app.ptt.talk
echo "installed $APP"
