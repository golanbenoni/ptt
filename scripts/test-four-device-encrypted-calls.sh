#!/usr/bin/env bash
# Run the calls-v1 real-microphone matrix across two Android and two Apple
# devices. Account A and B each use independently keyed Android device 1 and
# iOS device 2 credentials, matching the product's two-device account limit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DRIVER="${PTT_CALL_MATRIX_ANDROID_DRIVER:-$ROOT/scripts/test-android-two-device-call-real-microphone.sh}"
IOS_DRIVER="${PTT_CALL_MATRIX_IOS_DRIVER:-$ROOT/scripts/test-ios-two-physical-call-real-microphone.sh}"
CROSS_DRIVER="${PTT_CALL_MATRIX_CROSS_DRIVER:-$ROOT/scripts/test-android-ios-physical-call-direction.sh}"

required=(
  PTT_ANDROID_DEVICE_1 PTT_ANDROID_DEVICE_2 PTT_IOS_DEVICE_1 PTT_IOS_DEVICE_2
  PTT_CALL_SERVER PTT_CALL_CONVERSATION_ID
  PTT_CALL_ACCOUNT_A_ACI PTT_CALL_ACCOUNT_B_ACI
  PTT_CALL_ACCOUNT_A_ANDROID_MAILBOX PTT_CALL_ACCOUNT_A_ANDROID_TOKEN
  PTT_CALL_ACCOUNT_A_ANDROID_IDENTITY_FIXTURE
  PTT_CALL_ACCOUNT_A_IOS_MAILBOX PTT_CALL_ACCOUNT_A_IOS_TOKEN
  PTT_CALL_ACCOUNT_A_IOS_IDENTITY_FIXTURE
  PTT_CALL_ACCOUNT_B_ANDROID_MAILBOX PTT_CALL_ACCOUNT_B_ANDROID_TOKEN
  PTT_CALL_ACCOUNT_B_ANDROID_IDENTITY_FIXTURE
  PTT_CALL_ACCOUNT_B_IOS_MAILBOX PTT_CALL_ACCOUNT_B_IOS_TOKEN
  PTT_CALL_ACCOUNT_B_IOS_IDENTITY_FIXTURE
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "$name is required for the physical call matrix." >&2; exit 1; }
done

[[ "$PTT_CALL_ACCOUNT_A_ACI" != "$PTT_CALL_ACCOUNT_B_ACI" ]] || {
  echo "The physical call matrix requires two distinct accounts." >&2
  exit 1
}
for driver in "$ANDROID_DRIVER" "$IOS_DRIVER" "$CROSS_DRIVER"; do
  [[ -x "$driver" ]] || { echo "Physical call matrix driver is not executable: $driver" >&2; exit 1; }
done

export PTT_ANDROID_SKIP_INSTALL=1
export PTT_CALL_DIAGNOSTIC_AUDIO=1
export PTT_CALL_REQUIRE_REAL_MIC_AUDIO=1
export PTT_CALL_FORCE_SPEAKER=1
export PTT_CALL_PROOF_DURATION_MS=20000
export PTT_CALL_ACTIVE_HOOK="${PTT_CALL_MICROPHONE_STIMULUS:-$ROOT/scripts/play-call-microphone-fixture.sh}"

run_android_same_platform() {
  local caller_device="$1" callee_device="$2" caller_prefix="$3" callee_prefix="$4"
  local caller_aci_var="PTT_CALL_ACCOUNT_${caller_prefix}_ACI"
  local callee_aci_var="PTT_CALL_ACCOUNT_${callee_prefix}_ACI"
  local caller_mailbox_var="PTT_CALL_ACCOUNT_${caller_prefix}_ANDROID_MAILBOX"
  local caller_token_var="PTT_CALL_ACCOUNT_${caller_prefix}_ANDROID_TOKEN"
  local caller_fixture_var="PTT_CALL_ACCOUNT_${caller_prefix}_ANDROID_IDENTITY_FIXTURE"
  local callee_mailbox_var="PTT_CALL_ACCOUNT_${callee_prefix}_ANDROID_MAILBOX"
  local callee_token_var="PTT_CALL_ACCOUNT_${callee_prefix}_ANDROID_TOKEN"
  local callee_fixture_var="PTT_CALL_ACCOUNT_${callee_prefix}_ANDROID_IDENTITY_FIXTURE"
  PTT_ANDROID_DEVICE_1="$caller_device" PTT_ANDROID_DEVICE_2="$callee_device" \
  PTT_CALL_CALLER_ACI="${!caller_aci_var}" PTT_CALL_CALLER_DEVICE_ID=1 \
  PTT_CALL_CALLER_MAILBOX="${!caller_mailbox_var}" PTT_CALL_CALLER_TOKEN="${!caller_token_var}" \
  PTT_CALL_CALLER_IDENTITY_FIXTURE="${!caller_fixture_var}" \
  PTT_CALL_CALLEE_ACI="${!callee_aci_var}" PTT_CALL_CALLEE_DEVICE_ID=1 \
  PTT_CALL_CALLEE_MAILBOX="${!callee_mailbox_var}" PTT_CALL_CALLEE_TOKEN="${!callee_token_var}" \
  PTT_CALL_CALLEE_IDENTITY_FIXTURE="${!callee_fixture_var}" \
  PTT_CALL_MATRIX_KIND=android \
    "$ANDROID_DRIVER"
}

run_ios_same_platform() {
  local caller_device="$1" callee_device="$2" caller_prefix="$3" callee_prefix="$4"
  local caller_aci_var="PTT_CALL_ACCOUNT_${caller_prefix}_ACI"
  local callee_aci_var="PTT_CALL_ACCOUNT_${callee_prefix}_ACI"
  local caller_mailbox_var="PTT_CALL_ACCOUNT_${caller_prefix}_IOS_MAILBOX"
  local caller_token_var="PTT_CALL_ACCOUNT_${caller_prefix}_IOS_TOKEN"
  local caller_fixture_var="PTT_CALL_ACCOUNT_${caller_prefix}_IOS_IDENTITY_FIXTURE"
  local callee_mailbox_var="PTT_CALL_ACCOUNT_${callee_prefix}_IOS_MAILBOX"
  local callee_token_var="PTT_CALL_ACCOUNT_${callee_prefix}_IOS_TOKEN"
  local callee_fixture_var="PTT_CALL_ACCOUNT_${callee_prefix}_IOS_IDENTITY_FIXTURE"
  PTT_IOS_DEVICE_1="$caller_device" PTT_IOS_DEVICE_2="$callee_device" \
  PTT_CALL_CALLER_ACI="${!caller_aci_var}" PTT_CALL_CALLER_DEVICE_ID=2 \
  PTT_CALL_CALLER_MAILBOX="${!caller_mailbox_var}" PTT_CALL_CALLER_TOKEN="${!caller_token_var}" \
  PTT_CALL_CALLER_IDENTITY_FIXTURE="${!caller_fixture_var}" \
  PTT_CALL_CALLEE_ACI="${!callee_aci_var}" PTT_CALL_CALLEE_DEVICE_ID=2 \
  PTT_CALL_CALLEE_MAILBOX="${!callee_mailbox_var}" PTT_CALL_CALLEE_TOKEN="${!callee_token_var}" \
  PTT_CALL_CALLEE_IDENTITY_FIXTURE="${!callee_fixture_var}" \
  PTT_CALL_MATRIX_KIND=ios \
    "$IOS_DRIVER"
}

run_cross_platform() {
  local direction="$1"
  PTT_CALL_DIRECTION="$direction" PTT_ANDROID_DEVICE="$PTT_ANDROID_DEVICE_1" \
  PTT_IOS_DEVICE="$PTT_IOS_DEVICE_2" \
  PTT_ANDROID_ACI="$PTT_CALL_ACCOUNT_A_ACI" PTT_ANDROID_DEVICE_ID=1 \
  PTT_ANDROID_MAILBOX="$PTT_CALL_ACCOUNT_A_ANDROID_MAILBOX" \
  PTT_ANDROID_TOKEN="$PTT_CALL_ACCOUNT_A_ANDROID_TOKEN" \
  PTT_ANDROID_IDENTITY_FIXTURE="$PTT_CALL_ACCOUNT_A_ANDROID_IDENTITY_FIXTURE" \
  PTT_IOS_ACI="$PTT_CALL_ACCOUNT_B_ACI" PTT_IOS_DEVICE_ID=2 \
  PTT_IOS_MAILBOX="$PTT_CALL_ACCOUNT_B_IOS_MAILBOX" \
  PTT_IOS_TOKEN="$PTT_CALL_ACCOUNT_B_IOS_TOKEN" \
  PTT_IOS_IDENTITY_FIXTURE="$PTT_CALL_ACCOUNT_B_IOS_IDENTITY_FIXTURE" \
  PTT_CALL_MATRIX_KIND=cross \
    "$CROSS_DRIVER"
}

echo "Proving Android account A to account B physical microphone delivery."
run_android_same_platform "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2" A B
echo "Proving Android account B to account A physical microphone delivery."
run_android_same_platform "$PTT_ANDROID_DEVICE_2" "$PTT_ANDROID_DEVICE_1" B A
echo "Proving iOS account A to account B physical microphone delivery."
run_ios_same_platform "$PTT_IOS_DEVICE_1" "$PTT_IOS_DEVICE_2" A B
echo "Proving iOS account B to account A physical microphone delivery."
run_ios_same_platform "$PTT_IOS_DEVICE_2" "$PTT_IOS_DEVICE_1" B A
echo "Proving Android to iOS physical microphone delivery."
run_cross_platform android-to-ios
echo "Proving iOS to Android physical microphone delivery."
run_cross_platform ios-to-android
echo "Four-device calls-v1 real-microphone matrix passed in every required platform direction."
