#!/usr/bin/env bash
# Prepare isolated unattended ad-hoc signing for registered physical Apple devices.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${IOS_DISTRIBUTION_P12_BASE64:?IOS_DISTRIBUTION_P12_BASE64 is required}"
: "${IOS_DISTRIBUTION_P12_PASSWORD:?IOS_DISTRIBUTION_P12_PASSWORD is required}"
if (( $# < 1 )); then
  echo "usage: prepare-ios-physical-signing.sh CORE_DEVICE_ID..." >&2
  exit 64
fi

SIGNING_DIR="$RUNNER_TEMP/ptt-physical-signing-$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}"
KEYCHAIN="$SIGNING_DIR/ptt-physical.keychain-db"
P12="$SIGNING_DIR/distribution.p12"
CERTIFICATE="$SIGNING_DIR/distribution.pem"
PROFILE="$SIGNING_DIR/physical.mobileprovision"
PROFILE_PLIST="$SIGNING_DIR/physical.plist"
KEYCHAIN_PASSWORD="$(openssl rand -base64 36)"
mkdir -p "$SIGNING_DIR" "$HOME/Library/MobileDevice/Provisioning Profiles"
chmod 700 "$SIGNING_DIR"

printf '%s' "$IOS_DISTRIBUTION_P12_BASE64" | openssl base64 -d -A -out "$P12"
chmod 600 "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" \
  -P "$IOS_DISTRIBUTION_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -q 'Apple Distribution'

openssl pkcs12 -in "$P12" -clcerts -nokeys \
  -passin env:IOS_DISTRIBUTION_P12_PASSWORD -out "$CERTIFICATE"
CERTIFICATE_SERIAL="$(openssl x509 -in "$CERTIFICATE" -noout -serial | sed 's/^serial=//')"
test -n "$CERTIFICATE_SERIAL"

DEVICE_UDIDS=()
for device in "$@"; do
  details="$SIGNING_DIR/device-${#DEVICE_UDIDS[@]}.json"
  xcrun devicectl device info details --device "$device" --json-output "$details" >/dev/null
  udid="$(jq -er '.result.hardwareProperties.udid' "$details")"
  DEVICE_UDIDS+=("$udid")
done
if [[ "$(printf '%s\n' "${DEVICE_UDIDS[@]}" | sort -u | wc -l | tr -d ' ')" != "${#DEVICE_UDIDS[@]}" ]]; then
  echo "Apple physical signing requires distinct hardware UDIDs" >&2
  exit 1
fi

node "$ROOT/scripts/app-store-connect-profile.mjs" create \
  "$PROFILE" "$CERTIFICATE_SERIAL" "${DEVICE_UDIDS[@]}"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
PROFILE_UUID="$(plutil -extract UUID raw "$PROFILE_PLIST")"
PROFILE_NAME="$(plutil -extract Name raw "$PROFILE_PLIST")"
INSTALLED_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
cp "$PROFILE" "$INSTALLED_PROFILE"

{
  echo "PTT_IOS_SIGNING_DIR=$SIGNING_DIR"
  echo "PTT_CI_KEYCHAIN=$KEYCHAIN"
  echo "PTT_CI_PROFILE_PATH=$INSTALLED_PROFILE"
  echo "PTT_IOS_PROFILE=$PROFILE_NAME"
} >> "$GITHUB_ENV"
echo "Prepared isolated ad-hoc signing for ${#DEVICE_UDIDS[@]} Apple device(s)."
