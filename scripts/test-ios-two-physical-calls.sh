#!/usr/bin/env bash
# Drive one encrypted 1:1 call through two signed product builds on distinct
# physical Apple devices. Unlike the simulator harness, this requires CallKit
# to activate the WebRTC audio session and both microphones to publish.
set -euo pipefail

: "${PTT_IOS_DEVICE_1:?PTT_IOS_DEVICE_1 is required}"
: "${PTT_IOS_DEVICE_2:?PTT_IOS_DEVICE_2 is required}"
: "${PTT_CALL_SERVER:?PTT_CALL_SERVER is required}"
: "${PTT_CALL_CONVERSATION_ID:?PTT_CALL_CONVERSATION_ID is required}"
: "${PTT_CALL_CALLER_ACI:?PTT_CALL_CALLER_ACI is required}"
: "${PTT_CALL_CALLER_MAILBOX:?PTT_CALL_CALLER_MAILBOX is required}"
: "${PTT_CALL_CALLER_TOKEN:?PTT_CALL_CALLER_TOKEN is required}"
: "${PTT_CALL_CALLER_IDENTITY_FIXTURE:?PTT_CALL_CALLER_IDENTITY_FIXTURE is required}"
: "${PTT_CALL_CALLEE_ACI:?PTT_CALL_CALLEE_ACI is required}"
: "${PTT_CALL_CALLEE_MAILBOX:?PTT_CALL_CALLEE_MAILBOX is required}"
: "${PTT_CALL_CALLEE_TOKEN:?PTT_CALL_CALLEE_TOKEN is required}"
: "${PTT_CALL_CALLEE_IDENTITY_FIXTURE:?PTT_CALL_CALLEE_IDENTITY_FIXTURE is required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"
DEVICE_TIMEOUT="${PTT_IOS_DEVICE_COMMAND_TIMEOUT_SECONDS:-12}"
CALLER_DEVICE_ID="${PTT_CALL_CALLER_DEVICE_ID:-1}"
CALLEE_DEVICE_ID="${PTT_CALL_CALLEE_DEVICE_ID:-1}"
DIAGNOSTIC_AUDIO="${PTT_CALL_DIAGNOSTIC_AUDIO:-0}"
REQUIRE_REAL_MIC_AUDIO="${PTT_CALL_REQUIRE_REAL_MIC_AUDIO:-0}"
CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-5000}"
ACTIVE_HOOK="${PTT_CALL_ACTIVE_HOOK:-}"
WORK_DIR="$(mktemp -d -t ptt-ios-physical-call.XXXXXX)"
CALL_ID=""

cleanup() {
  local exit_code=$?
  if [[ -n "$CALL_ID" ]]; then
    curl -sS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
      -H 'Content-Type: application/json' -d '{}' \
      "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  for device in "$PTT_IOS_DEVICE_1" "$PTT_IOS_DEVICE_2"; do
    "$ROOT/scripts/terminate-ios-talk-app.sh" "$device" >/dev/null 2>&1 || true
  done
  for pid_file in "$WORK_DIR"/console-*.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(<"$pid_file")"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
  return "$exit_code"
}
trap cleanup EXIT INT TERM

for command in xcrun jq node openssl curl ruby uuidgen; do
  command -v "$command" >/dev/null || { echo "Missing physical iOS call dependency: $command" >&2; exit 1; }
done
[[ "$PTT_IOS_DEVICE_1" != "$PTT_IOS_DEVICE_2" ]] || { echo "Two distinct Apple devices are required." >&2; exit 1; }
[[ "$PTT_CALL_SERVER" == https://* ]] || { echo "Physical calls require a trusted HTTPS control origin." >&2; exit 1; }
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}
[[ "$CALLER_DEVICE_ID" =~ ^[12]$ && "$CALLEE_DEVICE_ID" =~ ^[12]$ ]] || {
  echo "Call automation device IDs must be 1 or 2." >&2
  exit 1
}
[[ "$DIAGNOSTIC_AUDIO" =~ ^[01]$ && "$REQUIRE_REAL_MIC_AUDIO" =~ ^[01]$ ]] || {
  echo "Call diagnostic flags must be 0 or 1." >&2
  exit 1
}
if [[ ! "$CALL_PROOF_DURATION_MS" =~ ^[0-9]+$ ]] ||
  (( CALL_PROOF_DURATION_MS < 5000 || CALL_PROOF_DURATION_MS > 20000 )); then
  echo "PTT_CALL_PROOF_DURATION_MS must be between 5000 and 20000." >&2
  exit 1
fi
if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  [[ "$DIAGNOSTIC_AUDIO" == 1 ]] || {
    echo "Real-microphone proof requires PTT_CALL_DIAGNOSTIC_AUDIO=1." >&2
    exit 1
  }
  [[ -n "$ACTIVE_HOOK" && -x "$ACTIVE_HOOK" ]] || {
    echo "Real-microphone proof requires an executable PTT_CALL_ACTIVE_HOOK." >&2
    exit 1
  }
  (( CALL_PROOF_DURATION_MS >= 15000 )) || {
    echo "Real-microphone proof requires at least a 15000ms evidence window." >&2
    exit 1
  }
fi

bounded() { node "$ROOT/scripts/run-with-timeout.mjs" "$DEVICE_TIMEOUT" "$@"; }
console_key() { printf '%s' "$1" | tr -cd '[:alnum:]_-'; }

require_app() {
  local report
  report="$WORK_DIR/apps-$(uuidgen).json"
  bounded xcrun devicectl device info apps --device "$1" --bundle-id "$BUNDLE_ID" \
    --json-output "$report" >/dev/null
  ruby -rjson -e '
    result = JSON.parse(File.read(ARGV[0])).fetch("result", {})
    apps = result["apps"] || result["applications"] || []
    abort "missing signed debug app" unless apps.any? do |app|
      app["bundleIdentifier"] == ARGV[1] || app["bundleID"] == ARGV[1]
    end
  ' "$report" "$BUNDLE_ID"
}

decode_and_install_fixture() {
  local device="$1" encoded="$2" output
  output="$WORK_DIR/identity-$(console_key "$device").json"
  printf '%s' "$encoded" | openssl base64 -d -A -out "$output"
  ruby -rjson -e '
    f = JSON.parse(File.read(ARGV[0]))
    abort "invalid identity fixture" unless f.fetch("identityKeyPair").length >= 80
    abort "invalid registration ID" unless (1..0x3fff).cover?(f.fetch("registrationId"))
  ' "$output"
  bounded xcrun devicectl device copy to --device "$device" --source "$output" \
    --destination Documents/ptt-e2e-identity.json --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" >/dev/null
}

read_console_marker() {
  local key pointer log
  key="$(console_key "$1")"
  pointer="$WORK_DIR/console-$key.current"
  [[ -f "$pointer" ]] || return 0
  log="$(<"$pointer")"
  [[ -f "$log" ]] || return 0
  awk -v marker_name="$2" -f "$ROOT/scripts/read-ios-console-marker.awk" "$log"
}

read_marker() {
  local destination marker
  destination="$WORK_DIR/marker-$(uuidgen)"
  mkdir -p "$destination"
  if bounded xcrun devicectl device copy from --device "$1" \
    --source "Documents/ptt-e2e-$2.txt" --destination "$destination" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" >/dev/null 2>&1; then
    marker="$(find "$destination" -type f -print -quit)"
    [[ -n "$marker" ]] && tr -d '\r\n' <"$marker" && return 0
  fi
  read_console_marker "$1" "$2"
}

launch_role() {
  local device="$1" role="$2" aci="$3" mailbox="$4" token="$5" call_id="${6:-}"
  local peer_aci="${7:-}" device_id="${8:-1}" environment key console_log
  environment="$(jq -cn --arg token "$token" --arg aci "$aci" --arg mailbox "$mailbox" \
    --arg peer "$peer_aci" --arg callId "$call_id" --arg deviceId "$device_id" \
    --arg diagnosticAudio "$DIAGNOSTIC_AUDIO" --arg proofDuration "$CALL_PROOF_DURATION_MS" \
    '{PTT_E2E_ACCESS_TOKEN:$token,PTT_E2E_ACI:$aci,PTT_E2E_MAILBOX:$mailbox,
      PTT_E2E_DEVICE:$deviceId,PTT_CALL_PEER_ACI:$peer,PTT_CALL_ID:$callId,
      PTT_CALL_DIAGNOSTIC_AUDIO:$diagnosticAudio,PTT_CALL_PROOF_DURATION_MS:$proofDuration}')"
  key="$(console_key "$device")"
  console_log="$WORK_DIR/console-$key-$(uuidgen).log"
  printf '%s' "$console_log" >"$WORK_DIR/console-$key.current"
  xcrun devicectl device process launch --device "$device" --terminate-existing --activate --console \
    --environment-variables "$environment" "$BUNDLE_ID" --ptt-server "$PTT_CALL_SERVER" \
    "--ptt-e2e-$role" --ptt-e2e-reset-crypto --ptt-e2e-skip-voice \
    "--ptt-e2e-call-$([[ "$role" == sender ]] && echo caller || echo callee)" \
    >"$console_log" 2>&1 &
  printf '%s' "$!" >"$WORK_DIR/console-$key.pid"
}

wait_marker() {
  local value="" deadline=$((SECONDS + $4)) key pointer
  while ((SECONDS < deadline)); do
    value="$(read_marker "$1" "$2")"
    [[ "$value" == "$3" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "Physical iOS call marker $2 did not reach $3 (last value: $value)." >&2
  key="$(console_key "$1")"
  pointer="$WORK_DIR/console-$key.current"
  [[ -f "$pointer" ]] && tail -100 "$(<"$pointer")" | \
    sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}/[redacted-uuid]/g' >&2 || true
  return 1
}

require_app "$PTT_IOS_DEVICE_1"
require_app "$PTT_IOS_DEVICE_2"
decode_and_install_fixture "$PTT_IOS_DEVICE_1" "$PTT_CALL_CALLER_IDENTITY_FIXTURE"
decode_and_install_fixture "$PTT_IOS_DEVICE_2" "$PTT_CALL_CALLEE_IDENTITY_FIXTURE"

launch_role "$PTT_IOS_DEVICE_1" sender "$PTT_CALL_CALLER_ACI" \
  "$PTT_CALL_CALLER_MAILBOX" "$PTT_CALL_CALLER_TOKEN" "" "$PTT_CALL_CALLEE_ACI" "$CALLER_DEVICE_ID"
for _ in {1..90}; do
  CALL_ID="$(read_marker "$PTT_IOS_DEVICE_1" call-id)"
  [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && break
  state="$(read_marker "$PTT_IOS_DEVICE_1" call-state)"
  [[ "$state" == fail:* ]] && { echo "Physical iOS caller failed: $state" >&2; exit 1; }
  sleep 1
done
[[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "Physical iOS caller did not create a call." >&2; exit 1; }

launch_role "$PTT_IOS_DEVICE_2" receiver "$PTT_CALL_CALLEE_ACI" \
  "$PTT_CALL_CALLEE_MAILBOX" "$PTT_CALL_CALLEE_TOKEN" "$CALL_ID" "" "$CALLEE_DEVICE_ID"

if [[ -n "$ACTIVE_HOOK" ]]; then
  for device in "$PTT_IOS_DEVICE_1" "$PTT_IOS_DEVICE_2"; do
    active_at=""
    for _ in {1..150}; do
      active_at="$(read_marker "$device" call-active-at-ms)"
      [[ "$active_at" =~ ^[0-9]{13}$ ]] && break
      state="$(read_marker "$device" call-state)"
      [[ "$state" == fail:* ]] && {
        echo "Physical iOS call failed before the active-call hook on $device: $state" >&2
        exit 1
      }
      sleep 1
    done
    [[ "$active_at" =~ ^[0-9]{13}$ ]] || {
      echo "Physical iOS call did not become protected and active before the hook on $device." >&2
      exit 1
    }
  done
  PTT_CALL_ACTIVE_CALLER_DEVICE="$PTT_IOS_DEVICE_1" \
  PTT_CALL_ACTIVE_CALLEE_DEVICE="$PTT_IOS_DEVICE_2" \
    "$ACTIVE_HOOK"
fi
wait_marker "$PTT_IOS_DEVICE_1" call-state pass 150
wait_marker "$PTT_IOS_DEVICE_2" call-state pass 150

if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  capture_bursts="$(read_marker "$PTT_IOS_DEVICE_1" call-capture-tone-bursts)"
  capture_peak="$(read_marker "$PTT_IOS_DEVICE_1" call-capture-peak-rms)"
  render_bursts="$(read_marker "$PTT_IOS_DEVICE_2" call-render-tone-bursts)"
  render_peak="$(read_marker "$PTT_IOS_DEVICE_2" call-render-peak-rms)"
  capture_format="$(read_marker "$PTT_IOS_DEVICE_1" call-capture-format)"
  render_format="$(read_marker "$PTT_IOS_DEVICE_2" call-render-format)"
  [[ "$capture_bursts" == 5 ]] || {
    echo "The iOS caller microphone captured ${capture_bursts:-0}/5 diagnostic tone bursts (peak RMS ${capture_peak:-0})." >&2
    exit 1
  }
  [[ "$render_bursts" == 5 ]] || {
    echo "The iOS callee playback graph received ${render_bursts:-0}/5 microphone-originated tone bursts (peak RMS ${render_peak:-0})." >&2
    exit 1
  }
  [[ "$capture_format" != DISABLED && "$render_format" != DISABLED ]] || {
    echo "Real-microphone diagnostics did not attach to both iOS WebRTC audio graphs." >&2
    exit 1
  }
  echo "The physical iOS caller microphone captured all five external tones and the callee decrypted all five remote bursts."
fi

created_ms="$(read_marker "$PTT_IOS_DEVICE_1" call-created-at-ms)"
ringing_ms="$(read_marker "$PTT_IOS_DEVICE_2" call-ringing-at-ms)"
answered_ms="$(read_marker "$PTT_IOS_DEVICE_2" call-answered-at-ms)"
caller_media_ms="$(read_marker "$PTT_IOS_DEVICE_1" call-media-connected-at-ms)"
callee_media_ms="$(read_marker "$PTT_IOS_DEVICE_2" call-media-connected-at-ms)"
for value in "$created_ms" "$ringing_ms" "$answered_ms" "$caller_media_ms" "$callee_media_ms"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "A required physical iOS call timing marker is missing." >&2; exit 1; }
done
invite_to_ring_ms=$((ringing_ms - created_ms))
answer_to_media_ms=$(( (caller_media_ms > callee_media_ms ? caller_media_ms : callee_media_ms) - answered_ms ))
(( invite_to_ring_ms >= 0 && invite_to_ring_ms <= MAX_INVITE_TO_RING_MS )) || {
  echo "Physical iOS invite-to-ring was ${invite_to_ring_ms}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2
  exit 1
}
(( answer_to_media_ms >= 0 && answer_to_media_ms <= MAX_ANSWER_TO_MEDIA_MS )) || {
  echo "Physical iOS answer-to-protected-media was ${answer_to_media_ms}ms (limit ${MAX_ANSWER_TO_MEDIA_MS}ms)." >&2
  exit 1
}

curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
wait_marker "$PTT_IOS_DEVICE_1" call-teardown pass 30
wait_marker "$PTT_IOS_DEVICE_2" call-teardown pass 30
echo "Two-device physical iOS encrypted call passed CallKit activation, publication, protected media connection, and teardown (invite-to-ring ${invite_to_ring_ms}ms, answer-to-media ${answer_to_media_ms}ms)."
