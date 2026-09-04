#!/usr/bin/env bash
# Run the product's encrypted voice/chat probes on two dedicated physical Apple devices.
set -euo pipefail

: "${PTT_IOS_DEVICE_1:?PTT_IOS_DEVICE_1 is required}"
: "${PTT_IOS_DEVICE_2:?PTT_IOS_DEVICE_2 is required}"
: "${PTT_E2E_SERVER:?PTT_E2E_SERVER is required}"
: "${PTT_E2E_ACI:?PTT_E2E_ACI is required}"
: "${PTT_E2E_SENDER_MAILBOX:?PTT_E2E_SENDER_MAILBOX is required}"
: "${PTT_E2E_RECEIVER_MAILBOX:?PTT_E2E_RECEIVER_MAILBOX is required}"
: "${PTT_E2E_SENDER_TOKEN:?PTT_E2E_SENDER_TOKEN is required}"
: "${PTT_E2E_RECEIVER_TOKEN:?PTT_E2E_RECEIVER_TOKEN is required}"
: "${PTT_E2E_SENDER_IDENTITY_FIXTURE:?PTT_E2E_SENDER_IDENTITY_FIXTURE is required}"
: "${PTT_E2E_RECEIVER_IDENTITY_FIXTURE:?PTT_E2E_RECEIVER_IDENTITY_FIXTURE is required}"

BUNDLE_ID="${PTT_IOS_AUTOMATION_BUNDLE_ID:-app.ptt.talk}"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
MAX_FLOOR_LATENCY_MS="${PTT_E2E_MAX_FLOOR_LATENCY_MS:-150}"
MAX_READY_LATENCY_MS="${PTT_E2E_MAX_READY_LATENCY_MS:-400}"
DEVICE_COMMAND_TIMEOUT_SECONDS="${PTT_IOS_DEVICE_COMMAND_TIMEOUT_SECONDS:-8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d -t ptt-ios-physical.XXXXXX)"

cleanup() {
  for pid_file in "$WORK_DIR"/console-*.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in xcrun jq node openssl ruby uuidgen; do
  command -v "$command" >/dev/null || {
    echo "Missing physical-test dependency: $command" >&2
    exit 1
  }
done

bounded() {
  node "$ROOT/scripts/run-with-timeout.mjs" "$DEVICE_COMMAND_TIMEOUT_SECONDS" "$@"
}

console_key() {
  printf '%s' "$1" | tr -cd '[:alnum:]_-'
}

stop_console() {
  local key pid_file pid
  key="$(console_key "$1")"
  pid_file="$WORK_DIR/console-$key.pid"
  [[ -f "$pid_file" ]] || return 0
  pid="$(cat "$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..10}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

read_console_marker() {
  local device="$1"
  local name="$2"
  local key pointer log
  key="$(console_key "$device")"
  pointer="$WORK_DIR/console-$key.current"
  [[ -f "$pointer" ]] || return 0
  log="$(cat "$pointer")"
  [[ -f "$log" ]] || return 0
  awk -v marker_name="$name" -f "$ROOT/scripts/read-ios-console-marker.awk" "$log"
}

report_console_diagnostics() {
  local device="$1"
  local key pointer log
  key="$(console_key "$device")"
  pointer="$WORK_DIR/console-$key.current"
  [[ -f "$pointer" ]] || { echo "No device console was captured." >&2; return; }
  log="$(cat "$pointer")"
  [[ -f "$log" ]] || { echo "The device console file is unavailable." >&2; return; }
  echo "Last redacted PTT device-console events:" >&2
  grep -E 'PTT_E2E_|dyld|fatal|crash|exception|error|failed' "$log" 2>/dev/null \
    | tail -40 \
    | sed -E \
        -e 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}/[redacted-uuid]/g' \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[redacted-email]/g' >&2 || true
}

if [[ "$PTT_IOS_DEVICE_1" == "$PTT_IOS_DEVICE_2" ]]; then
  echo "Physical voice validation requires two different Apple devices." >&2
  exit 1
fi
if [[ ! "$TRANSMISSIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_E2E_TRANSMISSIONS must be a positive integer." >&2
  exit 1
fi

require_debug_app() {
  local device="$1"
  local report
  report="$WORK_DIR/apps-$(uuidgen).json"
  if ! bounded xcrun devicectl device info apps --device "$device" --bundle-id "$BUNDLE_ID" \
    --json-output "$report" >/dev/null 2>&1; then
    echo "Apple device $device is offline, locked, untrusted, or unavailable." >&2
    return 1
  fi
  ruby -rjson -e '
    result = JSON.parse(File.read(ARGV.fetch(0))).fetch("result", {})
    apps = result["apps"] || result["applications"] || []
    wanted = ARGV.fetch(1)
    abort "missing app" unless apps.any? do |app|
      app["bundleIdentifier"] == wanted || app["bundleID"] == wanted
    end
  ' "$report" "$BUNDLE_ID" >/dev/null 2>&1 || {
    echo "Dedicated debug app $BUNDLE_ID is not installed on Apple device $device." >&2
    return 1
  }
}

decode_fixture() {
  local encoded="$1"
  local output="$2"
  printf '%s' "$encoded" | openssl base64 -d -A -out "$output"
  ruby -rjson -e '
    fixture = JSON.parse(File.read(ARGV.fetch(0)))
    abort "invalid identity fixture" unless fixture.fetch("identityKeyPair").length >= 80
    abort "invalid registration ID" unless (1..0x3fff).cover?(fixture.fetch("registrationId"))
  ' "$output"
}

install_fixture() {
  local device="$1"
  local fixture="$2"
  bounded xcrun devicectl device copy to --device "$device" --source "$fixture" \
    --destination Documents/ptt-e2e-identity.json --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" >/dev/null
}

read_marker() {
  local device="$1"
  local name="$2"
  local destination
  destination="$WORK_DIR/marker-$(uuidgen)"
  mkdir -p "$destination"
  if ! bounded xcrun devicectl device copy from --device "$device" \
    --source "Documents/ptt-e2e-$name.txt" --destination "$destination" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" >/dev/null 2>&1; then
    read_console_marker "$device" "$name"
    return 0
  fi
  local marker
  marker="$(find "$destination" -type f -print -quit)"
  if [[ -n "$marker" ]]; then
    tr -d '\r\n' < "$marker"
  else
    read_console_marker "$device" "$name"
  fi
}

write_marker() {
  local device="$1"
  local name="$2"
  local value="$3"
  local source
  source="$WORK_DIR/write-marker-$(uuidgen).txt"
  printf '%s' "$value" > "$source"
  bounded xcrun devicectl device copy to --device "$device" --source "$source" \
    --destination "Documents/ptt-e2e-$name.txt" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" >/dev/null
}

wait_for_marker() {
  local device="$1"
  local name="$2"
  local expected="$3"
  local timeout_seconds="$4"
  local value=""
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    value="$(read_marker "$device" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "Apple marker $name did not reach $expected on $device (last value: $value)." >&2
  report_console_diagnostics "$device"
  return 1
}

terminate_app_process() {
  local device="$1"
  local report
  report="$WORK_DIR/processes-$(uuidgen).json"
  bounded xcrun devicectl device info processes --device "$device" --json-output "$report" >/dev/null
  local pid
  pid="$(ruby -rjson -e '
    root = JSON.parse(File.read(ARGV.fetch(0)))
    wanted = ARGV.fetch(1)
    matches = []
    walk = lambda do |value|
      case value
      when Hash
        pid = value["processIdentifier"] || value["pid"]
        strings = value.values.grep(String)
        if pid && strings.any? { |item| item.include?(wanted) || item.include?("/PTT Talk.app/") || item == "PTT Talk" }
          matches << pid
        end
        value.each_value { |child| walk.call(child) }
      when Array
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(root.fetch("result", root))
    abort "missing app process" if matches.empty?
    puts matches.first
  ' "$report" "$BUNDLE_ID")" || {
    echo "Could not resolve the Apple receiver process." >&2
    return 1
  }
  bounded xcrun devicectl device process terminate --device "$device" --pid "$pid" --kill >/dev/null
}

launch_role() {
  local device="$1"
  local role="$2"
  local device_id="$3"
  local mailbox="$4"
  local token="$5"
  local chat_run="$6"
  shift 6
  local environment
  environment="$(jq -cn \
    --arg token "$token" \
    --arg aci "$PTT_E2E_ACI" \
    --arg mailbox "$mailbox" \
    --arg device "$device_id" \
    --arg run "$chat_run" \
    '{PTT_E2E_ACCESS_TOKEN:$token,PTT_E2E_ACI:$aci,PTT_E2E_MAILBOX:$mailbox,PTT_E2E_DEVICE:$device,PTT_E2E_CHAT_RUN:$run}')"
  local arguments=(--ptt-server "$PTT_E2E_SERVER" "--ptt-e2e-$role")
  if [[ "$role" == sender ]]; then arguments+=(--ptt-synthetic-mic); fi
  arguments+=("$@")
  local key console_log console_pid
  key="$(console_key "$device")"
  stop_console "$device"
  console_log="$WORK_DIR/console-$key-$(uuidgen).log"
  printf '%s' "$console_log" > "$WORK_DIR/console-$key.current"
  xcrun devicectl device process launch --device "$device" --terminate-existing --console \
    --environment-variables "$environment" "$BUNDLE_ID" "${arguments[@]}" >"$console_log" 2>&1 &
  console_pid=$!
  printf '%s' "$console_pid" > "$WORK_DIR/console-$key.pid"
  sleep 1
  if ! kill -0 "$console_pid" 2>/dev/null; then
    wait "$console_pid" 2>/dev/null || true
    echo "Could not launch the $role automation app on Apple device $device." >&2
    report_console_diagnostics "$device"
    return 1
  fi
}

run_process_restart_delivery() {
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  echo "Starting Apple receiver for process-death delivery gate"
  launch_role "$PTT_IOS_DEVICE_2" receiver 2 "$PTT_E2E_RECEIVER_MAILBOX" \
    "$PTT_E2E_RECEIVER_TOKEN" "$run" --ptt-e2e-restart-receiver --ptt-e2e-skip-voice
  echo "Queueing Apple message behind an injected delivery interruption"
  launch_role "$PTT_IOS_DEVICE_1" sender 1 "$PTT_E2E_SENDER_MAILBOX" \
    "$PTT_E2E_SENDER_TOKEN" "$run" --ptt-e2e-queue-before-crash --ptt-e2e-skip-voice
  local queue_deadline=$((SECONDS + 90))
  while ((SECONDS < queue_deadline)); do
    local state count
    state="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)"
    count="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-count)"
    [[ "$state" == fail:* ]] && { echo "Apple process-death queue failed: $state" >&2; return 1; }
    [[ "$state" == queued && "$count" == 1 ]] && break
    sleep 1
  done
  if [[ "$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)" != queued ]]; then
    echo "Apple message was not durably queued before process termination." >&2
    return 1
  fi

  echo "Terminating and relaunching Apple sender to prove durable retry"
  launch_role "$PTT_IOS_DEVICE_1" sender 1 "$PTT_E2E_SENDER_MAILBOX" \
    "$PTT_E2E_SENDER_TOKEN" "$run" --ptt-e2e-resume-after-crash --ptt-e2e-skip-voice
  local retry_deadline=$((SECONDS + 150))
  while ((SECONDS < retry_deadline)); do
    local sender_state receiver_state receiver_count
    sender_state="$(read_marker "$PTT_IOS_DEVICE_1" chat-restart-sender-state)"
    receiver_state="$(read_marker "$PTT_IOS_DEVICE_2" chat-restart-receiver-state)"
    receiver_count="$(read_marker "$PTT_IOS_DEVICE_2" chat-restart-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ]]; then
      echo "Apple process-death retry failed: sender=$sender_state receiver=$receiver_state" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$receiver_state" == pass && "$receiver_count" == 1 ]]; then
      echo "Apple process-death gate passed: encrypted outbox retried after relaunch"
      return 0
    fi
    sleep 1
  done
  echo "Apple process-death retry timed out." >&2
  return 1
}

run_background_push_wake() {
  local run
  run="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  echo "Preparing Apple receiver for the terminated-process Push to Talk wake gate"
  launch_role "$PTT_IOS_DEVICE_2" receiver 2 "$PTT_E2E_RECEIVER_MAILBOX" \
    "$PTT_E2E_RECEIVER_TOKEN" "$run" --ptt-e2e-push-wake-receiver --ptt-e2e-skip-voice
  wait_until_ready "Apple Push to Talk wake" "$PTT_IOS_DEVICE_2"
  wait_for_marker "$PTT_IOS_DEVICE_2" push-session-state persisted 30
  wait_for_marker "$PTT_IOS_DEVICE_2" push-registration-state registered 90
  write_marker "$PTT_IOS_DEVICE_2" incoming-push-state waiting
  write_marker "$PTT_IOS_DEVICE_2" push-audio-activation-state waiting
  terminate_app_process "$PTT_IOS_DEVICE_2"
  sleep 2

  echo "Transmitting while the Apple receiver app process is absent"
  launch_role "$PTT_IOS_DEVICE_1" sender 1 "$PTT_E2E_SENDER_MAILBOX" \
    "$PTT_E2E_SENDER_TOKEN" "$run"
  wait_for_marker "$PTT_IOS_DEVICE_2" incoming-push-state received 120
  wait_for_marker "$PTT_IOS_DEVICE_2" push-audio-activation-state activated 120
  wait_for_marker "$PTT_IOS_DEVICE_2" receiver-state pass 180
  wait_for_marker "$PTT_IOS_DEVICE_1" sender-state pass 180
  echo "Apple Push to Talk gate passed: APNs relaunched the app, activated audio, and completed playback"
}

wait_until_ready() {
  local label="$1"
  local device="$2"
  local state=""
  local deadline=$((SECONDS + 90))
  while ((SECONDS < deadline)); do
    state="$(read_marker "$device" receiver-state)"
    [[ "$state" == ready ]] && return 0
    if [[ "$state" == fail:* ]]; then
      echo "$label receiver setup failed: $state" >&2
      return 1
    fi
    sleep 1
  done
  echo "$label receiver did not become native-PTT ready within 90 seconds (last state: $state)." >&2
  report_console_diagnostics "$device"
  return 1
}

run_direction() {
  local label="$1"
  local sender_device="$2"
  local sender_id="$3"
  local sender_mailbox="$4"
  local sender_token="$5"
  local receiver_device="$6"
  local receiver_id="$7"
  local receiver_mailbox="$8"
  local receiver_token="$9"
  local chat_run
  chat_run="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  echo "Starting $label receiver through Apple's native Push to Talk path"
  launch_role "$receiver_device" receiver "$receiver_id" "$receiver_mailbox" "$receiver_token" "$chat_run"
  wait_until_ready "$label" "$receiver_device"
  echo "Starting $label sender with deterministic encrypted speech"
  launch_role "$sender_device" sender "$sender_id" "$sender_mailbox" "$sender_token" "$chat_run"

  local sender_state="" receiver_state="" sender_count="" receiver_count=""
  local chat_sender_state="" chat_receiver_state="" chat_sender_count="" chat_receiver_count=""
  local deadline=$((SECONDS + 180))
  local next_progress=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    sender_state="$(read_marker "$sender_device" sender-state)"
    receiver_state="$(read_marker "$receiver_device" receiver-state)"
    sender_count="$(read_marker "$sender_device" sender-count)"
    receiver_count="$(read_marker "$receiver_device" receiver-count)"
    chat_sender_state="$(read_marker "$sender_device" chat-sender-state)"
    chat_receiver_state="$(read_marker "$receiver_device" chat-receiver-state)"
    chat_sender_count="$(read_marker "$sender_device" chat-sender-count)"
    chat_receiver_count="$(read_marker "$receiver_device" chat-receiver-count)"
    if [[ "$sender_state" == fail:* || "$receiver_state" == fail:* ||
          "$chat_sender_state" == fail:* || "$chat_receiver_state" == fail:* ]]; then
      printf '%s failed: voice sender=%s/%s receiver=%s/%s chat sender=%s/%s receiver=%s/%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" \
        "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count" >&2
      return 1
    fi
    if [[ "$sender_state" == pass && "$sender_count" == "$TRANSMISSIONS" &&
          "$receiver_state" == pass && "$receiver_count" == "$TRANSMISSIONS" &&
          "$chat_sender_state" == pass && "$chat_sender_count" == 14 &&
          "$chat_receiver_state" == pass && "$chat_receiver_count" == 14 ]]; then
      "$ROOT/scripts/assert-latency-samples.sh" "$label floor grant" \
        "$(read_marker "$sender_device" floor-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_FLOOR_LATENCY_MS"
      "$ROOT/scripts/assert-latency-samples.sh" "$label communication ready" \
        "$(read_marker "$sender_device" ready-latencies-ms)" \
        "$TRANSMISSIONS" "$MAX_READY_LATENCY_MS"
      echo "$label passed $TRANSMISSIONS native encrypted PTT transmissions and the encrypted chat matrix"
      return 0
    fi
    if ((SECONDS >= next_progress)); then
      printf 'Waiting %s: voice sender=%s/%s receiver=%s/%s; chat sender=%s/%s receiver=%s/%s\n' \
        "$label" "$sender_state" "$sender_count" "$receiver_state" "$receiver_count" \
        "$chat_sender_state" "$chat_sender_count" "$chat_receiver_state" "$chat_receiver_count"
      next_progress=$((SECONDS + 15))
    fi
    sleep 1
  done
  echo "$label timed out before the native playback-completion markers reached parity." >&2
  return 1
}

require_debug_app "$PTT_IOS_DEVICE_1"
require_debug_app "$PTT_IOS_DEVICE_2"
decode_fixture "$PTT_E2E_SENDER_IDENTITY_FIXTURE" "$WORK_DIR/device-1.json"
decode_fixture "$PTT_E2E_RECEIVER_IDENTITY_FIXTURE" "$WORK_DIR/device-2.json"
install_fixture "$PTT_IOS_DEVICE_1" "$WORK_DIR/device-1.json"
install_fixture "$PTT_IOS_DEVICE_2" "$WORK_DIR/device-2.json"

run_direction device-1-to-device-2 \
  "$PTT_IOS_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN" \
  "$PTT_IOS_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN"
run_direction device-2-to-device-1 \
  "$PTT_IOS_DEVICE_2" 2 "$PTT_E2E_RECEIVER_MAILBOX" "$PTT_E2E_RECEIVER_TOKEN" \
  "$PTT_IOS_DEVICE_1" 1 "$PTT_E2E_SENDER_MAILBOX" "$PTT_E2E_SENDER_TOKEN"
run_background_push_wake
run_process_restart_delivery

echo "Two-physical-device Apple gate passed speaker playback, encrypted chat, APNs process wake, and process-death retry."
