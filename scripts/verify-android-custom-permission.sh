#!/usr/bin/env bash
# Ensure every Android variant owns a package-scoped hardware-PTT permission.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$ROOT/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT="${AAPT:-$SDK_ROOT/build-tools/36.0.0/aapt}"

test -f "$APK" || { echo "Android APK was not found: $APK" >&2; exit 1; }
test -x "$AAPT" || { echo "Android aapt was not found: $AAPT" >&2; exit 1; }

package="$($AAPT dump badging "$APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1)"
[[ -n "$package" ]] || { echo "Could not read the APK package name." >&2; exit 1; }
expected="$package.permission.HARDWARE_PTT"
permissions="$($AAPT dump permissions "$APK")"
xmltree="$($AAPT dump xmltree "$APK" AndroidManifest.xml)"

grep -Fqx "permission: $expected" <<<"$permissions" || {
  echo "APK does not declare its package-scoped hardware PTT permission: $expected" >&2
  exit 1
}

references="$(grep -Fc "$expected" <<<"$xmltree")"
[[ "$references" -eq 2 ]] || {
  echo "Expected the manifest to declare and enforce $expected exactly once each; found $references references." >&2
  exit 1
}

echo "Android custom permission is variant-safe: $expected"
