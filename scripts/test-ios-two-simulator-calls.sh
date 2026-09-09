#!/usr/bin/env bash
# Drive a real encrypted 1:1 call through two isolated iOS Simulator product
# instances. The simulator-only media mode deliberately leaves capture muted
# and avoids claiming CallKit or acoustic evidence; physical release automation
# must omit it.
set -euo pipefail

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
APP_PATH="${PTT_IOS_CALL_APP:-$ROOT/ios/TalkApp/.derived/Build/Products/Debug-iphonesimulator/TalkApp.app}"
BUNDLE_ID="app.ptt.talk"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"
KEEP_SIMULATORS_ON_FAILURE="${PTT_IOS_CALL_KEEP_SIMULATORS_ON_FAILURE:-0}"
WORK_DIR="$(mktemp -d -t ptt-ios-call.XXXXXX)"
CALL_ID=""
CALLER_ID=""
CALLEE_ID=""

cleanup() {
  local exit_code=$?
  if [[ -n "$CALL_ID" ]]; then
    curl -sS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
      -H 'Content-Type: application/json' -d '{}' \
      "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  if (( exit_code != 0 )) && [[ "$KEEP_SIMULATORS_ON_FAILURE" == "1" ]]; then
    echo "Preserving failed iOS call simulators for diagnosis:" >&2
    echo "  caller: $CALLER_ID" >&2
    echo "  callee: $CALLEE_ID" >&2
  else
    for simulator in "$CALLER_ID" "$CALLEE_ID"; do
      [[ -n "$simulator" ]] || continue
      xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
      xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    done
  fi
  rm -rf -- "$WORK_DIR"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

for command in xcrun openssl curl ruby codesign; do
  command -v "$command" >/dev/null || { echo "Missing iOS call-test dependency: $command" >&2; exit 1; }
done
test -d "$APP_PATH" || { echo "iOS simulator app was not found: $APP_PATH" >&2; exit 1; }
signature_details="$(codesign -dvv "$APP_PATH" 2>&1)" || {
  echo "The iOS simulator app is not signed for local execution: $APP_PATH" >&2
  exit 1
}
if ! grep -Fq "Identifier=$BUNDLE_ID" <<<"$signature_details" ||
   grep -Fq "linker-signed" <<<"$signature_details"; then
  echo "The iOS call gate requires a normally built simulator app with Keychain access." >&2
  echo "Rebuild without CODE_SIGNING_ALLOWED=NO before running this test." >&2
  exit 1
fi
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}
[[ "$KEEP_SIMULATORS_ON_FAILURE" == "0" || "$KEEP_SIMULATORS_ON_FAILURE" == "1" ]] || {
  echo "PTT_IOS_CALL_KEEP_SIMULATORS_ON_FAILURE must be 0 or 1." >&2
  exit 1
}

runtime="$(xcrun simctl list runtimes --json | ruby -rjson -e '
  runtimes = JSON.parse(STDIN.read).fetch("runtimes").select do |item|
    item["platform"] == "iOS" && item["isAvailable"] != false
  end
  selected = runtimes.max_by { |item| item.fetch("version", "0").split(".").map(&:to_i) }
  puts selected["identifier"] if selected
')"
device_type="${PTT_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
[[ -n "$runtime" ]] || { echo "No available iOS Simulator runtime was found." >&2; exit 1; }

CALLER_ID="$(xcrun simctl create "PTT Call caller $$" "$device_type" "$runtime")"
CALLEE_ID="$(xcrun simctl create "PTT Call callee $$" "$device_type" "$runtime")"

decode_fixture() {
  printf '%s' "$1" | openssl base64 -d -A -out "$2"
  ruby -rjson -e '
    fixture = JSON.parse(File.read(ARGV.fetch(0)))
    abort "invalid automation identity fixture" unless fixture.fetch("identityKeyPair").length >= 80
    abort "invalid automation registration ID" unless (1..0x3fff).cover?(fixture.fetch("registrationId"))
  ' "$2"
}

wait_for_boot() {
  xcrun simctl boot "$1"
  xcrun simctl bootstatus "$1" -b
}

read_marker() {
  local container="$1" name="$2"
  local marker="$container/Documents/ptt-e2e-$name.txt"
  [[ -f "$marker" ]] && tr -d '\r\n' <"$marker" || true
}

dump_diagnostics() {
  local simulator="$1" label="$2" container="${3:-}"
  echo "$label privacy-safe call diagnostics" >&2
  xcrun simctl spawn "$simulator" log show --style compact --last 10m \
    --predicate 'process == "TalkApp" AND eventMessage CONTAINS "PTT_"' 2>/dev/null | tail -240 >&2 || true
  if [[ -n "$container" && -d "$container/Documents" ]]; then
    echo "$label marker snapshot" >&2
    find "$container/Documents" -maxdepth 1 -type f -name 'ptt-e2e-*.txt' -print0 |
      while IFS= read -r -d '' marker; do
        printf '%s=%s\n' "$(basename "$marker" .txt)" "$(tr -d '\r\n' <"$marker")"
      done | sort >&2
  fi
}

wait_marker() {
  local simulator="$1" container="$2" name="$3" expected="$4" attempts="$5" value=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(read_marker "$container" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "iOS call marker $name did not reach $expected (last value: $value)." >&2
  dump_diagnostics "$simulator" "$name" "$container"
  return 1
}

decode_fixture "$PTT_CALL_CALLER_IDENTITY_FIXTURE" "$WORK_DIR/caller.json"
decode_fixture "$PTT_CALL_CALLEE_IDENTITY_FIXTURE" "$WORK_DIR/callee.json"
wait_for_boot "$CALLER_ID"
wait_for_boot "$CALLEE_ID"
for simulator in "$CALLER_ID" "$CALLEE_ID"; do
  xcrun simctl install "$simulator" "$APP_PATH"
  xcrun simctl privacy "$simulator" grant microphone "$BUNDLE_ID"
done
CALLER_CONTAINER="$(xcrun simctl get_app_container "$CALLER_ID" "$BUNDLE_ID" data)"
CALLEE_CONTAINER="$(xcrun simctl get_app_container "$CALLEE_ID" "$BUNDLE_ID" data)"
mkdir -p "$CALLER_CONTAINER/Documents" "$CALLEE_CONTAINER/Documents"
cp "$WORK_DIR/caller.json" "$CALLER_CONTAINER/Documents/ptt-e2e-identity.json"
cp "$WORK_DIR/callee.json" "$CALLEE_CONTAINER/Documents/ptt-e2e-identity.json"

caller_launch_output="$(SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_CALL_CALLER_TOKEN" \
SIMCTL_CHILD_PTT_E2E_ACI="$PTT_CALL_CALLER_ACI" \
SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_CALL_CALLER_MAILBOX" \
SIMCTL_CHILD_PTT_E2E_DEVICE=1 \
SIMCTL_CHILD_PTT_CALL_PEER_ACI="$PTT_CALL_CALLEE_ACI" \
xcrun simctl launch "$CALLER_ID" "$BUNDLE_ID" --ptt-server "$PTT_CALL_SERVER" \
  --ptt-e2e-sender --ptt-e2e-skip-voice --ptt-e2e-call-caller \
  --ptt-e2e-call-simulator-media-only 2>&1)" || {
  echo "Could not launch the iOS call caller: $caller_launch_output" >&2
  dump_diagnostics "$CALLER_ID" "caller-launch" "$CALLER_CONTAINER"
  exit 1
}
echo "Launched iOS call caller: $caller_launch_output"

for _ in {1..90}; do
  CALL_ID="$(read_marker "$CALLER_CONTAINER" call-id)"
  [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && break
  state="$(read_marker "$CALLER_CONTAINER" call-state)"
  if [[ "$state" == fail:* ]]; then
    echo "iOS caller failed before invitation: $state" >&2
    dump_diagnostics "$CALLER_ID" "call-creation" "$CALLER_CONTAINER"
    exit 1
  fi
  sleep 1
done
if [[ ! "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
  echo "iOS caller did not create a call." >&2
  dump_diagnostics "$CALLER_ID" "call-creation" "$CALLER_CONTAINER"
  exit 1
fi

SIMCTL_CHILD_PTT_E2E_ACCESS_TOKEN="$PTT_CALL_CALLEE_TOKEN" \
SIMCTL_CHILD_PTT_E2E_ACI="$PTT_CALL_CALLEE_ACI" \
SIMCTL_CHILD_PTT_E2E_MAILBOX="$PTT_CALL_CALLEE_MAILBOX" \
SIMCTL_CHILD_PTT_E2E_DEVICE=1 \
SIMCTL_CHILD_PTT_CALL_ID="$CALL_ID" \
xcrun simctl launch "$CALLEE_ID" "$BUNDLE_ID" --ptt-server "$PTT_CALL_SERVER" \
  --ptt-e2e-receiver --ptt-e2e-skip-voice --ptt-e2e-call-callee \
  --ptt-e2e-call-simulator-media-only >/dev/null

wait_marker "$CALLER_ID" "$CALLER_CONTAINER" call-state pass 150
wait_marker "$CALLEE_ID" "$CALLEE_CONTAINER" call-state pass 150

created_ms="$(read_marker "$CALLER_CONTAINER" call-created-at-ms)"
ringing_ms="$(read_marker "$CALLEE_CONTAINER" call-ringing-at-ms)"
answered_ms="$(read_marker "$CALLEE_CONTAINER" call-answered-at-ms)"
caller_media_ms="$(read_marker "$CALLER_CONTAINER" call-media-connected-at-ms)"
callee_media_ms="$(read_marker "$CALLEE_CONTAINER" call-media-connected-at-ms)"
for value in "$created_ms" "$ringing_ms" "$answered_ms" "$caller_media_ms" "$callee_media_ms"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "A required iOS call timing marker is missing." >&2; exit 1; }
done
invite_to_ring_ms=$((ringing_ms - created_ms))
answer_to_media_ms=$(( (caller_media_ms > callee_media_ms ? caller_media_ms : callee_media_ms) - answered_ms ))
(( invite_to_ring_ms >= 0 && invite_to_ring_ms <= MAX_INVITE_TO_RING_MS )) || {
  echo "iOS invite-to-ring latency was ${invite_to_ring_ms}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2
  exit 1
}
(( answer_to_media_ms >= 0 && answer_to_media_ms <= MAX_ANSWER_TO_MEDIA_MS )) || {
  echo "iOS answer-to-protected-media latency was ${answer_to_media_ms}ms (limit ${MAX_ANSWER_TO_MEDIA_MS}ms)." >&2
  exit 1
}

curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
wait_marker "$CALLER_ID" "$CALLER_CONTAINER" call-teardown pass 30
wait_marker "$CALLEE_ID" "$CALLEE_CONTAINER" call-teardown pass 30

echo "Two-simulator iOS encrypted call passed with E2EE room connection and teardown (invite-to-ring ${invite_to_ring_ms}ms, answer-to-media ${answer_to_media_ms}ms)."
echo "This is muted simulator protocol/media evidence; it is not CallKit, microphone publication, playback, or acoustic proof."
