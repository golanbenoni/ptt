#!/usr/bin/env bash
# Build libsignal FFI for the iOS simulator without OPENSSL_SMALL.
# Signal's swift/build_ffi.sh defines OPENSSL_SMALL on iOS, which disables
# ring's nistz P-256 and drops p256_point_mul_base_vartime (link failure).
set -euo pipefail
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CARGO_BUILD_TARGET=aarch64-apple-ios-sim
export IPHONEOS_DEPLOYMENT_TARGET=15
export RUSTFLAGS="--cfg aes_armv8 --cfg tokio_unstable"
ROOT="${LIBSIGNAL_ROOT:-${HOME}/src/libsignal}"
cd "$ROOT"
rm -rf "target/${CARGO_BUILD_TARGET}/debug/build/ring-"*
cargo build -p libsignal-ffi --features "libsignal-bridge-testing log/release_max_level_info"
echo "ok $ROOT/target/${CARGO_BUILD_TARGET}/debug/libsignal_ffi.a"
