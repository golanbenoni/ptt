#!/usr/bin/env bash
# Route one declared ChromeOS ARC serial through the Chromebook's pinned SSH channel.
set -euo pipefail

REAL_ADB="${PTT_LOCAL_ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
REMOTE_ALIAS="${PTT_REMOTE_ADB_ALIAS:-chromeos-arc}"
REMOTE_SERIAL="${PTT_REMOTE_ADB_SERIAL:-100.115.92.2:5555}"
REMOTE_HOST="${PTT_REMOTE_ADB_HOST:-}"
REMOTE_PORT="${PTT_REMOTE_ADB_SSH_PORT:-2222}"
REMOTE_USER="${PTT_REMOTE_ADB_USER:-root}"
REMOTE_KEY="${PTT_REMOTE_ADB_KEY:-$HOME/.ssh/chromeos_brya_ed25519}"
REMOTE_KNOWN_HOSTS="${PTT_REMOTE_ADB_KNOWN_HOSTS:-$HOME/.ssh/chromeos_brya_known_hosts}"
REMOTE_SERVER_PORT="${PTT_REMOTE_ADB_SERVER_PORT:-5038}"

if [[ " $* " != *" -s $REMOTE_ALIAS "* ]]; then
  exec "$REAL_ADB" "$@"
fi

[[ -n "$REMOTE_HOST" ]] || { echo "PTT_REMOTE_ADB_HOST is required for $REMOTE_ALIAS." >&2; exit 2; }
[[ -f "$REMOTE_KEY" && -f "$REMOTE_KNOWN_HOSTS" ]] || {
  echo "Pinned ChromeOS SSH credentials are unavailable." >&2
  exit 1
}
SSH=(ssh -i "$REMOTE_KEY" -p "$REMOTE_PORT" -o BatchMode=yes -o ConnectTimeout=8 \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$REMOTE_KNOWN_HOSTS" \
  "$REMOTE_USER@$REMOTE_HOST")
REMOTE_TEMP=""

cleanup() {
  if [[ -n "$REMOTE_TEMP" ]]; then
    "${SSH[@]}" "rm -f '$REMOTE_TEMP'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ARGS=("$@")
COMMAND_INDEX=-1
for index in "${!ARGS[@]}"; do
  if [[ "${ARGS[$index]}" == -s && "${ARGS[$((index + 1))]:-}" == "$REMOTE_ALIAS" ]]; then
    ARGS[index + 1]="$REMOTE_SERIAL"
    COMMAND_INDEX=$((index + 2))
    break
  fi
done
(( COMMAND_INDEX >= 0 )) || { echo "Could not route ARC adb arguments." >&2; exit 2; }
COMMAND="${ARGS[$COMMAND_INDEX]:-}"

remote_adb() {
  local quoted="" argument
  for argument in "$@"; do
    printf -v quoted '%s %q' "$quoted" "$argument"
  done
  "${SSH[@]}" "ADB_SERVER_SOCKET=tcp:127.0.0.1:$REMOTE_SERVER_PORT adb$quoted"
}

transfer_to_host() {
  local source="$1" destination="$2"
  [[ -f "$source" ]] || { echo "adb router source file does not exist: $source" >&2; exit 1; }
  dd if="$source" bs=1048576 2>/dev/null | "${SSH[@]}" "dd of='$destination' bs=1048576 2>/dev/null"
}

case "$COMMAND" in
  install)
    LAST_INDEX=$((${#ARGS[@]} - 1))
    LOCAL_APK="${ARGS[$LAST_INDEX]}"
    APK_SHA="$(shasum -a 256 "$LOCAL_APK" | awk '{print $1}')"
    APK_SIZE="$(stat -f '%z' "$LOCAL_APK")"
    REMOTE_APK="/tmp/ptt-adb-router-cache-$APK_SHA.apk"
    if ! "${SSH[@]}" "test -f '$REMOTE_APK' && test \"\$(stat -c %s '$REMOTE_APK')\" = '$APK_SIZE'"; then
      "${SSH[@]}" "find /tmp -maxdepth 1 -type f -name 'ptt-adb-router-cache-*.apk' -delete" >/dev/null
      transfer_to_host "$LOCAL_APK" "$REMOTE_APK"
    fi
    ARGS[LAST_INDEX]="$REMOTE_APK"
    remote_adb "${ARGS[@]}"
    ;;
  push)
    SOURCE_INDEX=$((COMMAND_INDEX + 1))
    LOCAL_SOURCE="${ARGS[$SOURCE_INDEX]}"
    REMOTE_SOURCE="/tmp/ptt-adb-router-$(date +%s)-$$-$(basename "$LOCAL_SOURCE")"
    transfer_to_host "$LOCAL_SOURCE" "$REMOTE_SOURCE"
    ARGS[SOURCE_INDEX]="$REMOTE_SOURCE"
    REMOTE_TEMP="$REMOTE_SOURCE"
    remote_adb "${ARGS[@]}"
    ;;
  *)
    remote_adb "${ARGS[@]}"
    ;;
esac
