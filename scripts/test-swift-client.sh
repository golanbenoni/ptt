#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PTT_IOS_SIMULATOR_ID:?Set PTT_IOS_SIMULATOR_ID to a dedicated test simulator}"
export LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$HOME/src/libsignal/swift}"
export LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$HOME/src/libsignal/target/aarch64-apple-ios-sim/debug}"
export PTT_NATIVE_TARGET_DIR="${PTT_NATIVE_TARGET_DIR:-$ROOT/native/target/aarch64-apple-ios-sim/release}"
export PTT_LIBRARY_TESTS_ONLY=1
test -f "$LIBSIGNAL_FFI/libsignal_ffi.a"
test -f "$PTT_NATIVE_TARGET_DIR/libptt_apple_ffi.a"
cd "$ROOT"
# Keychain tests require the signed app host, not the unentitled SPM xctest process.
xcodebuild test -project ios/TalkApp/TalkApp.xcodeproj -scheme PttTalkClientTests \
  -destination "platform=iOS Simulator,id=$PTT_IOS_SIMULATOR_ID" \
  -derivedDataPath "$ROOT/ios/TalkApp/.derived-client-tests" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64 \
  "OTHER_LDFLAGS=\$(inherited) -L$LIBSIGNAL_FFI -lsignal_ffi -L$PTT_NATIVE_TARGET_DIR -lptt_apple_ffi -lresolv -lc++ -lcompression" "$@"
