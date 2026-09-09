#!/usr/bin/env bash
# Test-only recorder for validating the four-device matrix's credential and
# platform mapping without accessing hardware or exposing real credentials.
set -euo pipefail

: "${PTT_CALL_MATRIX_LOG:?PTT_CALL_MATRIX_LOG is required}"
: "${PTT_CALL_MATRIX_KIND:?PTT_CALL_MATRIX_KIND is required}"

case "$PTT_CALL_MATRIX_KIND" in
  android)
    printf 'android|%s|%s|%s|%s|%s|%s\n' \
      "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2" \
      "$PTT_CALL_CALLER_ACI" "$PTT_CALL_CALLEE_ACI" \
      "$PTT_CALL_CALLER_DEVICE_ID" "$PTT_CALL_CALLEE_DEVICE_ID" >>"$PTT_CALL_MATRIX_LOG"
    ;;
  ios)
    printf 'ios|%s|%s|%s|%s|%s|%s\n' \
      "$PTT_IOS_DEVICE_1" "$PTT_IOS_DEVICE_2" \
      "$PTT_CALL_CALLER_ACI" "$PTT_CALL_CALLEE_ACI" \
      "$PTT_CALL_CALLER_DEVICE_ID" "$PTT_CALL_CALLEE_DEVICE_ID" >>"$PTT_CALL_MATRIX_LOG"
    ;;
  cross)
    printf 'cross|%s|%s|%s|%s|%s|%s|%s\n' \
      "$PTT_CALL_DIRECTION" "$PTT_ANDROID_DEVICE" "$PTT_IOS_DEVICE" \
      "$PTT_ANDROID_ACI" "$PTT_IOS_ACI" "$PTT_ANDROID_DEVICE_ID" "$PTT_IOS_DEVICE_ID" \
      >>"$PTT_CALL_MATRIX_LOG"
    ;;
  *)
    echo "Unexpected physical call matrix kind: $PTT_CALL_MATRIX_KIND" >&2
    exit 1
    ;;
esac
