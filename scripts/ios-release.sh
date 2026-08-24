#!/usr/bin/env bash
# Build and verify a signed App Store Connect IPA without storing signing assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBSIGNAL_ROOT="${LIBSIGNAL_ROOT:-${HOME}/src/libsignal}"
LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$LIBSIGNAL_ROOT/swift}"
LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$LIBSIGNAL_ROOT/target/aarch64-apple-ios/release}"
ARCHIVE="$ROOT/ios/TalkApp/build/release/PTT-Talk.xcarchive"
EXPORT="$ROOT/ios/TalkApp/build/release/export"
NATIVE="$ROOT/native/target/aarch64-apple-ios/release/libptt_apple_ffi.a"
PROFILE_NAME="${PTT_IOS_PROFILE:-PTT Talk App Store}"
SIGNING_IDENTITY="${PTT_IOS_SIGNING_IDENTITY:-Apple Distribution}"
DEVELOPMENT_TEAM="${PTT_IOS_DEVELOPMENT_TEAM:-M2M4752Z6K}"
TEMP_DIR="$(mktemp -d -t ptt-ios-release.XXXXXX)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

test -d "$LIBSIGNAL_SWIFT"
if [[ ! -f "$LIBSIGNAL_FFI/libsignal_ffi.a" ]]; then
  echo "missing $LIBSIGNAL_FFI/libsignal_ffi.a; build pinned libsignal v0.101.0 for aarch64-apple-ios first" >&2
  exit 1
fi

if [[ ! -f "$NATIVE" ]]; then
  "$ROOT/scripts/build-apple-native.sh"
fi

shopt -s nullglob
PROFILE_PATH=""
for candidate in \
  "${HOME}/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision \
  "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision
do
  candidate_name="$(security cms -D -i "$candidate" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)"
  if [[ "$candidate_name" == "$PROFILE_NAME" ]]; then
    PROFILE_PATH="$candidate"
    break
  fi
done
if [[ -z "$PROFILE_PATH" ]]; then
  echo "missing provisioning profile: $PROFILE_NAME" >&2
  exit 1
fi
if ! security cms -D -i "$PROFILE_PATH" 2>/dev/null | \
  plutil -extract Entitlements xml1 - -o - | \
  grep -q 'com.apple.developer.push-to-talk'
then
  echo "provisioning profile '$PROFILE_NAME' lacks Apple's managed Push to Talk entitlement" >&2
  echo "request/enable Push to Talk for app.ptt.talk, then create and install a new App Store profile" >&2
  exit 1
fi

EXPORT_OPTIONS="$TEMP_DIR/ExportOptions.plist"
cp "$ROOT/ios/TalkApp/ExportOptions.plist" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :provisioningProfiles:app.ptt.talk $PROFILE_NAME" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :signingCertificate $SIGNING_IDENTITY" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"

xcodebuild \
  -project "$ROOT/ios/TalkApp/TalkApp.xcodeproj" \
  -scheme TalkApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  LIBRARY_SEARCH_PATHS="$LIBSIGNAL_FFI $(dirname "$NATIVE")" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  archive

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' -print -quit)"
test -n "$IPA"
VERIFY_DIR="$TEMP_DIR/verify"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$IPA" "$VERIFY_DIR"
APP="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -name '*.app' -print -quit)"
test -n "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.developer.push-to-talk'

(
  cd "$(dirname "$IPA")"
  shasum -a 256 "$(basename "$IPA")" > "$(basename "$IPA").sha256"
)
echo "$IPA"
echo "$IPA.sha256"
