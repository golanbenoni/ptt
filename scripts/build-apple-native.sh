#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root/native"

cargo build --release -p ptt-apple-ffi

if command -v xcrun >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
  cargo build --release -p ptt-apple-ffi --target aarch64-apple-ios
  cargo build --release -p ptt-apple-ffi --target aarch64-apple-ios-sim
fi

# A final Apple app links both libsignal_ffi and this independent Rust archive.
# Rust's single C ABI personality symbol is intentionally identical, so make
# this archive's copy weak and let the linker coalesce it with libsignal's.
rust_sysroot=$(rustc --print sysroot)
objcopy="$rust_sysroot/lib/rustlib/aarch64-apple-darwin/bin/rust-objcopy"
for archive in \
  target/release/libptt_apple_ffi.a \
  target/aarch64-apple-ios/release/libptt_apple_ffi.a \
  target/aarch64-apple-ios-sim/release/libptt_apple_ffi.a
do
  if [[ -f "$archive" ]]; then
    DYLD_LIBRARY_PATH="$rust_sysroot/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
      "$objcopy" --weaken-symbol=_rust_eh_personality "$archive"
  fi
done
