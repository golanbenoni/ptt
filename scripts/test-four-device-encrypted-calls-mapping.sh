#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d -t ptt-call-matrix-mapping.XXXXXX)"
LOG="$WORK_DIR/matrix.log"
FIXTURE="$ROOT/scripts/record-four-device-call-matrix-fixture.sh"

cleanup() { find "$WORK_DIR" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT INT TERM

export PTT_CALL_MATRIX_LOG="$LOG"
export PTT_CALL_MATRIX_ANDROID_DRIVER="$FIXTURE"
export PTT_CALL_MATRIX_IOS_DRIVER="$FIXTURE"
export PTT_CALL_MATRIX_CROSS_DRIVER="$FIXTURE"
export PTT_ANDROID_DEVICE_1=android-a
export PTT_ANDROID_DEVICE_2=android-b
export PTT_IOS_DEVICE_1=ios-a
export PTT_IOS_DEVICE_2=ios-b
export PTT_CALL_SERVER=https://control.example.test
export PTT_CALL_CONVERSATION_ID=11111111-1111-4111-8111-111111111111
export PTT_CALL_ACCOUNT_A_ACI=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
export PTT_CALL_ACCOUNT_B_ACI=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb

for account in A B; do
  for platform in ANDROID IOS; do
    export "PTT_CALL_ACCOUNT_${account}_${platform}_MAILBOX=${account}-${platform}-mailbox"
    export "PTT_CALL_ACCOUNT_${account}_${platform}_TOKEN=${account}-${platform}-token"
    export "PTT_CALL_ACCOUNT_${account}_${platform}_IDENTITY_FIXTURE=${account}-${platform}-fixture"
  done
done

"$ROOT/scripts/test-four-device-encrypted-calls.sh" >/dev/null

actual="$(<"$LOG")"
expected="$(printf '%s\n' \
  'android|android-a|android-b|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|1|1' \
  'android|android-b|android-a|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|1|1' \
  'ios|ios-a|ios-b|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|2|2' \
  'ios|ios-b|ios-a|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|2|2' \
  'cross|android-to-ios|android-a|ios-b|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|1|2' \
  'cross|ios-to-android|android-a|ios-b|aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb|1|2')"

[[ "$actual" == "$expected" ]] || {
  echo "Four-device call matrix credential mapping changed unexpectedly." >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
}
echo "Four-device encrypted-call credential and platform mapping passed."
