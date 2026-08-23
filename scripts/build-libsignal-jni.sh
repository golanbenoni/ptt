#!/usr/bin/env bash
# Build libsignal-jni for this host and install as native/jni/libsignal_jni.so
# Needed on linux aarch64: the published jar only embeds linux-amd64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${LIBSIGNAL_SRC:-/tmp/libsignal-src}"
TAG="${LIBSIGNAL_TAG:-v0.101.0}"
OUT="$ROOT/native/jni"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$TAG" https://github.com/signalapp/libsignal.git "$SRC"
fi
export PATH="${HOME}/.local/bin:${PATH}"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export BINDGEN_EXTRA_CLANG_ARGS="${BINDGEN_EXTRA_CLANG_ARGS:--I/usr/lib/gcc/aarch64-linux-gnu/13/include -I/usr/include/aarch64-linux-gnu -I/usr/include}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-18/lib}"
export PROTOC="${PROTOC:-${HOME}/.local/bin/protoc}"
(cd "$SRC" && cargo build -p libsignal-jni --release)
mkdir -p "$OUT"
# crate-type cdylib, lib name signal_jni
cp "$SRC/target/release/libsignal_jni.so" "$OUT/libsignal_jni.so"
echo "installed $OUT/libsignal_jni.so"
