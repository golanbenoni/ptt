#!/usr/bin/env bash
# Build and verify a signed App Store Connect IPA without storing signing assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBSIGNAL_ROOT="${LIBSIGNAL_ROOT:-${HOME}/src/libsignal}"
LIBSIGNAL_SWIFT="${LIBSIGNAL_SWIFT:-$LIBSIGNAL_ROOT/swift}"
LIBSIGNAL_FFI="${LIBSIGNAL_FFI:-$LIBSIGNAL_ROOT/target/aarch64-apple-ios/release}"
export LIBSIGNAL_SWIFT LIBSIGNAL_FFI
ARCHIVE="$ROOT/ios/TalkApp/build/release/PTT-Talk.xcarchive"
EXPORT="$ROOT/ios/TalkApp/build/release/export"
NATIVE="$ROOT/native/target/aarch64-apple-ios/release/libptt_apple_ffi.a"
PROFILE_NAME="${PTT_IOS_PROFILE:-PTT Talk App Store}"
SIGNING_IDENTITY="${PTT_IOS_SIGNING_IDENTITY:-Apple Distribution}"
DEVELOPMENT_TEAM="${PTT_IOS_DEVELOPMENT_TEAM:-M2M4752Z6K}"
FOREGROUND_FALLBACK="${PTT_IOS_FOREGROUND_FALLBACK:-0}"
AUTOMATIC_SIGNING="${PTT_IOS_AUTOMATIC_SIGNING:-0}"
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
  [[ "$candidate_name" == "$PROFILE_NAME" ]] || continue
  PROFILE_PATH="$candidate"
  if security cms -D -i "$candidate" 2>/dev/null | \
    plutil -extract Entitlements xml1 - -o - | \
    grep -q 'com.apple.developer.associated-domains'; then
    break
  fi
done
if [[ -z "$PROFILE_PATH" ]]; then
  echo "missing provisioning profile: $PROFILE_NAME" >&2
  exit 1
fi
HAS_PTT_ENTITLEMENT=0
if security cms -D -i "$PROFILE_PATH" 2>/dev/null | \
  plutil -extract Entitlements xml1 - -o - | \
  grep -q 'com.apple.developer.push-to-talk'; then
  HAS_PTT_ENTITLEMENT=1
fi
HAS_ASSOCIATED_DOMAINS=0
if security cms -D -i "$PROFILE_PATH" 2>/dev/null | \
  plutil -extract Entitlements xml1 - -o - | \
  grep -q 'com.apple.developer.associated-domains'; then
  HAS_ASSOCIATED_DOMAINS=1
fi
if [[ "$HAS_ASSOCIATED_DOMAINS" != 1 ]]; then
  echo "provisioning profile '$PROFILE_NAME' lacks the Associated Domains entitlement" >&2
  echo "enable Associated Domains for app.ptt.talk and install a refreshed App Store profile" >&2
  exit 1
fi
if [[ "$HAS_PTT_ENTITLEMENT" != 1 && "$FOREGROUND_FALLBACK" != 1 ]]; then
  echo "provisioning profile '$PROFILE_NAME' lacks Apple's managed Push to Talk entitlement" >&2
  echo "request/enable Push to Talk for app.ptt.talk, then create and install a new App Store profile" >&2
  echo "or set PTT_IOS_FOREGROUND_FALLBACK=1 to ship foreground-only encrypted PTT while approval is pending" >&2
  exit 1
fi

EXPORT_OPTIONS="$TEMP_DIR/ExportOptions.plist"
cp "$ROOT/ios/TalkApp/ExportOptions.plist" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :provisioningProfiles:app.ptt.talk $PROFILE_NAME" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :signingCertificate $SIGNING_IDENTITY" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
if [[ "$AUTOMATIC_SIGNING" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Delete :provisioningProfiles' "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Set :signingStyle automatic' "$EXPORT_OPTIONS"
fi

ARCHIVE_OVERRIDES=()
if [[ "$HAS_PTT_ENTITLEMENT" != 1 ]]; then
  FALLBACK_ENTITLEMENTS="$TEMP_DIR/TalkApp.entitlements"
  FALLBACK_INFO="$TEMP_DIR/Info.plist"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>com.apple.developer.associated-domains</key><array><string>applinks:ptttalk.app</string></array></dict></plist>' > "$FALLBACK_ENTITLEMENTS"
  cp "$ROOT/ios/TalkApp/Info.plist" "$FALLBACK_INFO"
  /usr/libexec/PlistBuddy -c 'Delete :UIBackgroundModes:1' "$FALLBACK_INFO"
  /usr/libexec/PlistBuddy -c 'Set :PTTUsesSystemFramework false' "$FALLBACK_INFO"
  ARCHIVE_OVERRIDES+=(
    "CODE_SIGN_ENTITLEMENTS=$FALLBACK_ENTITLEMENTS"
    "INFOPLIST_FILE=$FALLBACK_INFO"
  )
  echo "building foreground-only iOS beta; managed Push to Talk entitlement is pending"
fi

SIGNING_OVERRIDES=(
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
)
PROVISIONING_ARGS=()
if [[ "$AUTOMATIC_SIGNING" == 1 ]]; then
  SIGNING_OVERRIDES+=("CODE_SIGN_STYLE=Automatic")
  PROVISIONING_ARGS+=(-allowProvisioningUpdates)
else
  SIGNING_OVERRIDES+=(
    "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
    "CODE_SIGN_STYLE=Manual"
    "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_NAME"
  )
fi

xcodebuild \
  -project "$ROOT/ios/TalkApp/TalkApp.xcodeproj" \
  -scheme TalkApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  "${PROVISIONING_ARGS[@]}" \
  LIBRARY_SEARCH_PATHS="$LIBSIGNAL_FFI $(dirname "$NATIVE")" \
  "${SIGNING_OVERRIDES[@]}" \
  "${ARCHIVE_OVERRIDES[@]}" \
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
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.developer.associated-domains'
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'applinks:ptttalk.app'
if [[ "$HAS_PTT_ENTITLEMENT" == 1 ]]; then
  codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.developer.push-to-talk'
else
  if codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.developer.push-to-talk'; then
    echo "foreground fallback unexpectedly contains the managed Push to Talk entitlement" >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$APP/Info.plist" 2>/dev/null | grep -q 'push-to-talk'; then
    echo "foreground fallback unexpectedly advertises Push to Talk background mode" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :PTTUsesSystemFramework' "$APP/Info.plist" 2>/dev/null || true)" != false ]]; then
    echo "foreground fallback unexpectedly enables the system Push to Talk framework" >&2
    exit 1
  fi
fi

(
  cd "$(dirname "$IPA")"
  shasum -a 256 "$(basename "$IPA")" > "$(basename "$IPA").sha256"
)
echo "$IPA"
echo "$IPA.sha256"
