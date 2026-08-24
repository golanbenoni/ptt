#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK_ROOT=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [[ -z "$SDK_ROOT" ]]; then
  ANDROID_SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
  if [[ -z "$ANDROID_SDK" || ! -d "$ANDROID_SDK/ndk" ]]; then
    echo "Set ANDROID_HOME/ANDROID_SDK_ROOT or ANDROID_NDK_HOME to build the Android codec." >&2
    exit 1
  fi
  SDK_ROOT=$(find "$ANDROID_SDK/ndk" -mindepth 1 -maxdepth 1 -type d -print | sort -V | tail -1)
fi
if [[ ! -d "$SDK_ROOT" ]]; then
  echo "Android NDK not found at $SDK_ROOT" >&2
  exit 1
fi
if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "cargo-ndk is required: cargo install cargo-ndk --locked" >&2
  exit 1
fi

export ANDROID_NDK_HOME=$SDK_ROOT
cd "$ROOT/native"
cargo ndk \
  -t arm64-v8a \
  -t armeabi-v7a \
  -t x86_64 \
  -o "$ROOT/android/audio/src/main/jniLibs" \
  build --release --locked -p ptt-android-jni

