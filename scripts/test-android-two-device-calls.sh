#!/usr/bin/env bash
# Drive a real encrypted 1:1 call through two Android runtimes. This validates
# Core-Telecom registration, account/API state, Double Ratchet key exchange,
# LiveKit E2EE connection, audio activation, and remote teardown. External
# acoustic capture and the complete physical matrix remain separate release evidence.
set -euo pipefail

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
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
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
APK="${PTT_ANDROID_AUTOMATION_APK:-$ROOT/android/talk/build/outputs/apk/debug/talkandroid-debug.apk}"
PACKAGE="app.ptt.talk.debug"
ACTIVITY="$PACKAGE/app.ptt.talk.PhysicalE2EActivity"
SKIP_INSTALL="${PTT_ANDROID_SKIP_INSTALL:-0}"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_ACTIVE_MS="${PTT_CALL_MAX_ANSWER_TO_ACTIVE_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"
# A product answer follows a visible ringing state. Wait for the same bounded, keyless
# directory/PQXDH preparation that runs behind that UI; set 0 only for the explicit
# immediate-answer stress diagnostic.
WAIT_FOR_PREWARM="${PTT_CALL_WAIT_FOR_PREWARM:-1}"
CALLER_DEVICE_ID="${PTT_CALL_CALLER_DEVICE_ID:-1}"
CALLEE_DEVICE_ID="${PTT_CALL_CALLEE_DEVICE_ID:-1}"
SYNTHETIC_AUDIO="${PTT_CALL_SYNTHETIC_AUDIO:-0}"
DIAGNOSTIC_AUDIO="${PTT_CALL_DIAGNOSTIC_AUDIO:-$SYNTHETIC_AUDIO}"
REQUIRE_REAL_MIC_AUDIO="${PTT_CALL_REQUIRE_REAL_MIC_AUDIO:-0}"
FORCE_CALL_SPEAKER="${PTT_CALL_FORCE_SPEAKER:-0}"
MUTE_CALLEE_DURING_HOOK="${PTT_CALL_MUTE_CALLEE_DURING_HOOK:-$REQUIRE_REAL_MIC_AUDIO}"
ATTENUATE_CALLEE_OUTPUT_DURING_HOOK="${PTT_CALL_ATTENUATE_CALLEE_OUTPUT_DURING_HOOK:-$REQUIRE_REAL_MIC_AUDIO}"
ACTIVE_HOOK="${PTT_CALL_ACTIVE_HOOK:-}"
INSPECTION_HOOK="${PTT_CALL_INSPECTION_HOOK:-}"
CALL_PROOF_DURATION_MS="${PTT_CALL_PROOF_DURATION_MS:-5000}"
WORK_DIR="$(mktemp -d -t ptt-android-call.XXXXXX)"
CALL_ID=""
REVERSED_PORTS=()
CALLEE_OUTPUT_ORIGINAL_VOLUME=""

restore_callee_output_volume() {
  if [[ "$CALLEE_OUTPUT_ORIGINAL_VOLUME" =~ ^[0-9]+$ ]]; then
    local expected_volume="$CALLEE_OUTPUT_ORIGINAL_VOLUME" restored_volume=""
    "$ADB" -s "$PTT_ANDROID_DEVICE_2" shell cmd media_session volume \
      --stream 0 --set "$expected_volume" >/dev/null 2>&1 || return 1
    restored_volume="$(
      "$ADB" -s "$PTT_ANDROID_DEVICE_2" shell cmd media_session volume --stream 0 --get 2>/dev/null |
        sed -nE 's/.*volume is ([0-9]+) in range.*/\1/p' | tail -1
    )"
    [[ "$restored_volume" == "$expected_volume" ]] || return 1
    CALLEE_OUTPUT_ORIGINAL_VOLUME=""
  fi
}

cleanup() {
  restore_callee_output_volume || true
  if [[ -n "$CALL_ID" ]]; then
    curl -sS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
      -H 'Content-Type: application/json' -d '{}' \
      "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null 2>&1 || true
  fi
  local serial port
  for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
    "$ADB" -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    for port in "${REVERSED_PORTS[@]}"; do
      "$ADB" -s "$serial" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
    done
  done
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for command in jq openssl uuidgen curl; do
  command -v "$command" >/dev/null || { echo "Missing call-test dependency: $command" >&2; exit 1; }
done
test -x "$ADB" || { echo "adb was not found at $ADB" >&2; exit 1; }
[[ "$SKIP_INSTALL" == 0 || "$SKIP_INSTALL" == 1 ]] || {
  echo "PTT_ANDROID_SKIP_INSTALL must be 0 or 1." >&2
  exit 1
}
if [[ "$SKIP_INSTALL" == 0 ]]; then
  test -f "$APK" || { echo "Android debug automation APK was not found: $APK" >&2; exit 1; }
fi
[[ "$PTT_ANDROID_DEVICE_1" != "$PTT_ANDROID_DEVICE_2" ]] || {
  echo "Two different Android runtimes are required." >&2
  exit 1
}
LOCAL_CONTROL_PORT=""
if [[ "$PTT_CALL_SERVER" =~ ^http://(127\.0\.0\.1|localhost):([1-9][0-9]{1,4})$ ]]; then
  LOCAL_CONTROL_PORT="${BASH_REMATCH[2]}"
elif [[ "$PTT_CALL_SERVER" != https://* ]]; then
  echo "The device call driver requires loopback HTTP or a trusted HTTPS control origin." >&2
  exit 1
fi
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ && "$MAX_ANSWER_TO_ACTIVE_MS" =~ ^[1-9][0-9]*$ &&
  "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Call latency limits must be positive integers." >&2
  exit 1
}
[[ "$WAIT_FOR_PREWARM" == 0 || "$WAIT_FOR_PREWARM" == 1 ]] || {
  echo "PTT_CALL_WAIT_FOR_PREWARM must be 0 or 1." >&2
  exit 1
}
[[ "$CALLER_DEVICE_ID" =~ ^[12]$ && "$CALLEE_DEVICE_ID" =~ ^[12]$ ]] || {
  echo "Call automation device IDs must be 1 or 2." >&2
  exit 1
}
[[ "$SYNTHETIC_AUDIO" == 0 || "$SYNTHETIC_AUDIO" == 1 ]] || {
  echo "PTT_CALL_SYNTHETIC_AUDIO must be 0 or 1." >&2
  exit 1
}
for setting in \
  "PTT_CALL_DIAGNOSTIC_AUDIO:$DIAGNOSTIC_AUDIO" \
  "PTT_CALL_REQUIRE_REAL_MIC_AUDIO:$REQUIRE_REAL_MIC_AUDIO" \
  "PTT_CALL_FORCE_SPEAKER:$FORCE_CALL_SPEAKER" \
  "PTT_CALL_MUTE_CALLEE_DURING_HOOK:$MUTE_CALLEE_DURING_HOOK" \
  "PTT_CALL_ATTENUATE_CALLEE_OUTPUT_DURING_HOOK:$ATTENUATE_CALLEE_OUTPUT_DURING_HOOK"; do
  setting_name="${setting%%:*}"
  value="${setting#*:}"
  [[ "$value" == 0 || "$value" == 1 ]] || {
    echo "$setting_name must be 0 or 1." >&2
    exit 1
  }
done
if [[ -n "$ACTIVE_HOOK" && ! -x "$ACTIVE_HOOK" ]]; then
  echo "PTT_CALL_ACTIVE_HOOK must name an executable file." >&2
  exit 1
fi
if [[ -n "$INSPECTION_HOOK" && ! -x "$INSPECTION_HOOK" ]]; then
  echo "PTT_CALL_INSPECTION_HOOK must name an executable file." >&2
  exit 1
fi
if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  [[ "$SYNTHETIC_AUDIO" == 0 ]] || {
    echo "Real-microphone proof refuses post-capture synthetic audio." >&2
    exit 1
  }
  [[ "$DIAGNOSTIC_AUDIO" == 1 ]] || {
    echo "Real-microphone proof requires PTT_CALL_DIAGNOSTIC_AUDIO=1." >&2
    exit 1
  }
  [[ -n "$ACTIVE_HOOK" ]] || {
    echo "Real-microphone proof requires an external PTT_CALL_ACTIVE_HOOK stimulus." >&2
    exit 1
  }
fi
if ! [[ "$CALL_PROOF_DURATION_MS" =~ ^[0-9]+$ ]] ||
  (( CALL_PROOF_DURATION_MS < 5000 || CALL_PROOF_DURATION_MS > 20000 )); then
  echo "PTT_CALL_PROOF_DURATION_MS must be between 5000 and 20000." >&2
  exit 1
fi
if [[ "$SYNTHETIC_AUDIO" == 1 && "$CALL_PROOF_DURATION_MS" -lt 15000 ]]; then
  echo "Synthetic acoustic proof requires PTT_CALL_PROOF_DURATION_MS of at least 15000." >&2
  exit 1
fi
if [[ "$WAIT_FOR_PREWARM" == 1 ]]; then
  WAIT_FOR_PREWARM_JSON=true
else
  WAIT_FOR_PREWARM_JSON=false
fi
if [[ "$SYNTHETIC_AUDIO" == 1 ]]; then
  SYNTHETIC_AUDIO_JSON=true
else
  SYNTHETIC_AUDIO_JSON=false
fi
if [[ "$DIAGNOSTIC_AUDIO" == 1 ]]; then
  DIAGNOSTIC_AUDIO_JSON=true
else
  DIAGNOSTIC_AUDIO_JSON=false
fi
if [[ "$FORCE_CALL_SPEAKER" == 1 ]]; then
  FORCE_CALL_SPEAKER_JSON=true
else
  FORCE_CALL_SPEAKER_JSON=false
fi
if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
  MUTE_CALLEE_DURING_HOOK_JSON=true
else
  MUTE_CALLEE_DURING_HOOK_JSON=false
fi

decode_fixture() {
  printf '%s' "$1" | openssl base64 -d -A -out "$2"
  jq -e '(.identityKeyPair | length) >= 80 and .registrationId >= 1 and .registrationId <= 16383' "$2" >/dev/null
}

require_runtime() {
  local serial="$1"
  [[ "$($ADB -s "$serial" get-state 2>/dev/null || true)" == device ]] || {
    echo "Android runtime $serial is offline, unauthorized, or unavailable." >&2
    return 1
  }
}

copy_private_file() {
  local serial="$1" source="$2" name="$3" remote
  remote="/data/local/tmp/ptt-call-$name-$(uuidgen)"
  "$ADB" -s "$serial" push "$source" "$remote" >/dev/null
  "$ADB" -s "$serial" shell run-as "$PACKAGE" mkdir -p files
  "$ADB" -s "$serial" shell run-as "$PACKAGE" cp "$remote" "files/$name"
  "$ADB" -s "$serial" shell rm "$remote"
}

read_marker() {
  "$ADB" -s "$1" exec-out run-as "$PACKAGE" cat "files/ptt-e2e-$2.txt" 2>/dev/null | tr -d '\r\n' || true
}

prepare_role() {
  local serial="$1" role="$2" mode="$3" aci="$4" device_id="$5" mailbox="$6" token="$7"
  local fixture="$8" call_id="${9:-}" preserve_state="${10:-false}" wait_for_prewarm="${11:-false}"
  local synthetic_audio="${12:-false}" call_proof_duration_ms="${13:-5000}"
  local force_call_speaker="${14:-false}"
  local diagnostic_call_audio="${15:-false}"
  local mute_during_proof="${16:-false}"
  local skip_crypto_initialization=false
  if [[ "$mode" == call-caller || "$mode" == call-callee ]]; then
    skip_crypto_initialization=true
  fi
  local config="$WORK_DIR/config-$role.json"
  "$ADB" -s "$serial" shell run-as "$PACKAGE" sh -c "'rm -f files/ptt-e2e-*.txt'" >/dev/null
  jq -cn \
    --arg role "$role" --arg mode "$mode" --arg server "$PTT_CALL_SERVER" \
    --arg aci "$aci" --arg mailbox "$mailbox" --arg token "$token" \
    --arg channel "$PTT_CALL_CONVERSATION_ID" --arg run "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg peerAci "$PTT_CALL_CALLEE_ACI" --arg callId "$call_id" --argjson device "$device_id" \
    --argjson preserveState "$preserve_state" --argjson waitForPrewarm "$wait_for_prewarm" \
    --argjson syntheticCallAudio "$synthetic_audio" --argjson callProofDurationMs "$call_proof_duration_ms" \
    --argjson forceCallSpeaker "$force_call_speaker" \
    --argjson diagnosticCallAudio "$diagnostic_call_audio" \
    --argjson muteDuringProof "$mute_during_proof" \
    --argjson skipCryptoInitialization "$skip_crypto_initialization" \
    '{role:$role,mode:$mode,serverUrl:$server,aci:$aci,deviceId:$device,mailboxId:$mailbox,
      accessToken:$token,channelId:$channel,run:$run,transmissions:1,peerAci:$peerAci,
      callId:$callId,preserveState:$preserveState,waitForPrewarm:$waitForPrewarm,
      skipCryptoInitialization:$skipCryptoInitialization,syntheticCallAudio:$syntheticCallAudio,
      callProofDurationMs:$callProofDurationMs,forceCallSpeaker:$forceCallSpeaker,
      diagnosticCallAudio:$diagnosticCallAudio,muteDuringProof:$muteDuringProof}' \
    > "$config"
  copy_private_file "$serial" "$fixture" ptt-e2e-identity.json
  copy_private_file "$serial" "$config" ptt-e2e-config.json
}

launch_role() {
  "$ADB" -s "$1" shell am force-stop "$PACKAGE"
  "$ADB" -s "$1" logcat -c
  "$ADB" -s "$1" shell am start -n "$ACTIVITY" >/dev/null
}

wait_marker() {
  local serial="$1" name="$2" expected="$3" attempts="$4" value=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(read_marker "$serial" "$name")"
    [[ "$value" == "$expected" ]] && return 0
    [[ "$value" == fail:* ]] && break
    sleep 1
  done
  echo "Android call marker $name did not reach $expected on $serial (last value: $value)." >&2
  "$ADB" -s "$serial" logcat -d -v brief 2>/dev/null | grep -E 'PTT_E2E|AndroidRuntime' | tail -80 |
    sed -E 's/[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}/[redacted-uuid]/g' >&2 || true
  return 1
}

decode_fixture "$PTT_CALL_CALLER_IDENTITY_FIXTURE" "$WORK_DIR/caller-identity.json"
decode_fixture "$PTT_CALL_CALLEE_IDENTITY_FIXTURE" "$WORK_DIR/callee-identity.json"
for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
  require_runtime "$serial"
  if [[ "$SKIP_INSTALL" == 0 ]]; then
    "$ADB" -s "$serial" install -r -t "$APK" >/dev/null
  else
    "$ADB" -s "$serial" shell pm path "$PACKAGE" >/dev/null || {
      echo "Android runtime $serial does not have the requested preinstalled debug app." >&2
      exit 1
    }
  fi
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO >/dev/null
  "$ADB" -s "$serial" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
done

reverse_ports="${PTT_CALL_REVERSE_PORTS:-}"
if [[ -z "$reverse_ports" && -n "$LOCAL_CONTROL_PORT" ]]; then
  reverse_ports="$LOCAL_CONTROL_PORT,7880,7881"
fi
if [[ -n "$reverse_ports" ]]; then
  [[ -n "$LOCAL_CONTROL_PORT" ]] || {
    echo "adb reverse ports are not allowed for a public HTTPS call gate." >&2
    exit 1
  }
  IFS=',' read -r -a REVERSED_PORTS <<<"$reverse_ports"
  for port in "${REVERSED_PORTS[@]}"; do
    [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || { echo "Invalid adb reverse port: $port" >&2; exit 1; }
    for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
      "$ADB" -s "$serial" reverse "tcp:$port" "tcp:$port" >/dev/null
    done
  done
fi

prepare_role "$PTT_ANDROID_DEVICE_1" sender call-prepare "$PTT_CALL_CALLER_ACI" "$CALLER_DEVICE_ID" \
  "$PTT_CALL_CALLER_MAILBOX" "$PTT_CALL_CALLER_TOKEN" "$WORK_DIR/caller-identity.json"
prepare_role "$PTT_ANDROID_DEVICE_2" receiver call-prepare "$PTT_CALL_CALLEE_ACI" "$CALLEE_DEVICE_ID" \
  "$PTT_CALL_CALLEE_MAILBOX" "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/callee-identity.json"
launch_role "$PTT_ANDROID_DEVICE_1"
launch_role "$PTT_ANDROID_DEVICE_2"
wait_marker "$PTT_ANDROID_DEVICE_1" sender-state pass 120
wait_marker "$PTT_ANDROID_DEVICE_2" receiver-state pass 120

prepare_role "$PTT_ANDROID_DEVICE_1" sender call-caller "$PTT_CALL_CALLER_ACI" "$CALLER_DEVICE_ID" \
  "$PTT_CALL_CALLER_MAILBOX" "$PTT_CALL_CALLER_TOKEN" "$WORK_DIR/caller-identity.json" "" true false \
  "$SYNTHETIC_AUDIO_JSON" "$CALL_PROOF_DURATION_MS" "$FORCE_CALL_SPEAKER_JSON" \
  "$DIAGNOSTIC_AUDIO_JSON" false
launch_role "$PTT_ANDROID_DEVICE_1"
for _ in {1..60}; do
  CALL_ID="$(read_marker "$PTT_ANDROID_DEVICE_1" call-id)"
  [[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] && break
  caller_state="$(read_marker "$PTT_ANDROID_DEVICE_1" call-state)"
  [[ "$caller_state" == fail:* ]] && { echo "Caller failed before invitation: $caller_state" >&2; exit 1; }
  sleep 1
done
[[ "$CALL_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "Caller did not create an opaque call." >&2; exit 1; }

prepare_role "$PTT_ANDROID_DEVICE_2" receiver call-callee "$PTT_CALL_CALLEE_ACI" "$CALLEE_DEVICE_ID" \
  "$PTT_CALL_CALLEE_MAILBOX" "$PTT_CALL_CALLEE_TOKEN" "$WORK_DIR/callee-identity.json" \
  "$CALL_ID" true "$WAIT_FOR_PREWARM_JSON" false "$CALL_PROOF_DURATION_MS" \
  "$FORCE_CALL_SPEAKER_JSON" "$DIAGNOSTIC_AUDIO_JSON" "$MUTE_CALLEE_DURING_HOOK_JSON"
launch_role "$PTT_ANDROID_DEVICE_2"

if [[ -n "$ACTIVE_HOOK" || -n "$INSPECTION_HOOK" ]]; then
  for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
    active_at=""
    for _ in {1..150}; do
      active_at="$(read_marker "$serial" call-active-at-ms)"
      [[ "$active_at" =~ ^[0-9]{13}$ ]] && break
      state="$(read_marker "$serial" call-state)"
      [[ "$state" == fail:* ]] && {
        echo "Android call failed before the active-call hook on $serial: $state" >&2
        exit 1
      }
      sleep 1
    done
    [[ "$active_at" =~ ^[0-9]{13}$ ]] || {
      echo "Android call did not become protected and active before the hook on $serial." >&2
      exit 1
    }
  done
  if [[ -n "$INSPECTION_HOOK" ]]; then
    "$INSPECTION_HOOK"
  fi
fi

if [[ -n "$ACTIVE_HOOK" ]]; then
  if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
    wait_marker "$PTT_ANDROID_DEVICE_2" call-muted true 30
  fi
  if [[ "$ATTENUATE_CALLEE_OUTPUT_DURING_HOOK" == 1 ]]; then
    CALLEE_OUTPUT_ORIGINAL_VOLUME="$(
      "$ADB" -s "$PTT_ANDROID_DEVICE_2" shell cmd media_session volume --stream 0 --get 2>/dev/null |
        sed -nE 's/.*volume is ([0-9]+) in range.*/\1/p' | tail -1
    )"
    [[ "$CALLEE_OUTPUT_ORIGINAL_VOLUME" =~ ^[0-9]+$ ]] || {
      echo "Could not read the callee voice-call output volume for directional isolation." >&2
      exit 1
    }
    "$ADB" -s "$PTT_ANDROID_DEVICE_2" shell cmd media_session volume \
      --stream 0 --set 1 >/dev/null
  fi
  hook_status=0
  PTT_CALL_ACTIVE_CALLER_SERIAL="$PTT_ANDROID_DEVICE_1" \
  PTT_CALL_ACTIVE_CALLEE_SERIAL="$PTT_ANDROID_DEVICE_2" \
  PTT_CALL_ACTIVE_CALL_ID="$CALL_ID" \
  PTT_CALL_SERVER="$PTT_CALL_SERVER" \
  PTT_CALL_CALLER_TOKEN="$PTT_CALL_CALLER_TOKEN" \
    "$ACTIVE_HOOK" || hook_status=$?
  restore_callee_output_volume
  if [[ "$MUTE_CALLEE_DURING_HOOK" == 1 ]]; then
    "$ADB" -s "$PTT_ANDROID_DEVICE_2" shell run-as "$PACKAGE" \
      sh -c "'printf complete > files/ptt-e2e-call-hook-complete.txt'"
    wait_marker "$PTT_ANDROID_DEVICE_2" call-muted false 30
  fi
  (( hook_status == 0 )) || exit "$hook_status"
fi
wait_marker "$PTT_ANDROID_DEVICE_1" call-state pass 150
wait_marker "$PTT_ANDROID_DEVICE_2" call-state pass 150

if [[ "$SYNTHETIC_AUDIO" == 1 ]]; then
  render_bursts="$(read_marker "$PTT_ANDROID_DEVICE_2" call-render-tone-bursts)"
  render_peak="$(read_marker "$PTT_ANDROID_DEVICE_2" call-render-peak-rms)"
  [[ "$render_bursts" == "5" ]] || {
    echo "The callee playback graph detected ${render_bursts:-0}/5 decrypted diagnostic tone bursts (peak RMS ${render_peak:-0})." >&2
    exit 1
  }
  echo "The callee playback graph detected all five decrypted diagnostic tone bursts (peak RMS $render_peak)."
fi
if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  capture_bursts="$(read_marker "$PTT_ANDROID_DEVICE_1" call-capture-tone-bursts)"
  capture_peak="$(read_marker "$PTT_ANDROID_DEVICE_1" call-capture-peak-rms)"
  render_bursts="$(read_marker "$PTT_ANDROID_DEVICE_2" call-render-tone-bursts)"
  render_peak="$(read_marker "$PTT_ANDROID_DEVICE_2" call-render-peak-rms)"
  capture_format="$(read_marker "$PTT_ANDROID_DEVICE_1" call-capture-format)"
  render_format="$(read_marker "$PTT_ANDROID_DEVICE_2" call-render-format)"
  [[ "$capture_bursts" == "5" ]] || {
    echo "The caller microphone captured ${capture_bursts:-0}/5 diagnostic tone bursts (peak RMS ${capture_peak:-0})." >&2
    exit 1
  }
  [[ "$render_bursts" == "5" ]] || {
    echo "The callee playback graph received ${render_bursts:-0}/5 microphone-originated tone bursts (peak RMS ${render_peak:-0})." >&2
    exit 1
  }
  [[ "$capture_format" != DISABLED && "$render_format" != DISABLED ]] || {
    echo "Real-microphone diagnostics did not attach to both WebRTC audio graphs." >&2
    exit 1
  }
  echo "The physical caller microphone captured all five external tones and the callee decrypted all five remote bursts."
fi

created_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-created-at-ms)"
ringing_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-ringing-at-ms)"
answered_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-answered-at-ms)"
caller_active_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-active-at-ms)"
callee_active_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-active-at-ms)"
caller_connect_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-connect-at-ms)"
callee_connect_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-connect-at-ms)"
caller_seat_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-seat-at-ms)"
callee_seat_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-seat-at-ms)"
caller_key_sent_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-key-sent-at-ms)"
callee_key_sent_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-key-sent-at-ms)"
caller_remote_key_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-remote-key-at-ms)"
callee_remote_key_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-remote-key-at-ms)"
caller_key_acked_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-key-acked-at-ms)"
callee_key_acked_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-key-acked-at-ms)"
caller_media_connected_ms="$(read_marker "$PTT_ANDROID_DEVICE_1" call-media-connected-at-ms)"
callee_media_connected_ms="$(read_marker "$PTT_ANDROID_DEVICE_2" call-media-connected-at-ms)"
for value in "$created_ms" "$ringing_ms" "$answered_ms" "$caller_seat_ms" "$callee_seat_ms" \
  "$caller_key_sent_ms" "$callee_key_sent_ms" "$caller_remote_key_ms" "$callee_remote_key_ms" \
  "$caller_key_acked_ms" "$callee_key_acked_ms" "$caller_connect_ms" "$callee_connect_ms" \
  "$caller_media_connected_ms" "$callee_media_connected_ms" "$caller_active_ms" "$callee_active_ms"; do
  [[ "$value" =~ ^[0-9]{13}$ ]] || { echo "A required call timing marker is missing." >&2; exit 1; }
done
invite_to_ring_ms=$((ringing_ms - created_ms))
ring_to_answer_ms=$((answered_ms - ringing_ms))
answer_to_active_ms=$(( (caller_active_ms > callee_active_ms ? caller_active_ms : callee_active_ms) - answered_ms ))
answer_to_key_ready_ms=$(( (caller_connect_ms > callee_connect_ms ? caller_connect_ms : callee_connect_ms) - answered_ms ))
answer_to_media_ms=$(( (caller_media_connected_ms > callee_media_connected_ms ? caller_media_connected_ms : callee_media_connected_ms) - answered_ms ))
caller_media_connect_ms=$((caller_media_connected_ms - caller_connect_ms))
callee_media_connect_ms=$((callee_media_connected_ms - callee_connect_ms))
media_connect_ms=$((caller_media_connect_ms > callee_media_connect_ms ? caller_media_connect_ms : callee_media_connect_ms))
seat_claim_ms=$(( (caller_seat_ms > callee_seat_ms ? caller_seat_ms : callee_seat_ms) - answered_ms ))
key_send_ms=$(( (caller_key_sent_ms > callee_key_sent_ms ? caller_key_sent_ms : callee_key_sent_ms) - answered_ms ))
remote_key_ms=$(( (caller_remote_key_ms > callee_remote_key_ms ? caller_remote_key_ms : callee_remote_key_ms) - answered_ms ))
key_ack_ms=$(( (caller_key_acked_ms > callee_key_acked_ms ? caller_key_acked_ms : callee_key_acked_ms) - answered_ms ))
(( invite_to_ring_ms >= 0 && invite_to_ring_ms <= MAX_INVITE_TO_RING_MS )) || {
  echo "Invite-to-ring latency was ${invite_to_ring_ms}ms (limit ${MAX_INVITE_TO_RING_MS}ms)." >&2
  exit 1
}
(( answer_to_active_ms >= 0 && answer_to_active_ms <= MAX_ANSWER_TO_ACTIVE_MS )) || {
  echo "Answer-to-protected-audio readiness was ${answer_to_active_ms}ms (limit ${MAX_ANSWER_TO_ACTIVE_MS}ms)." >&2
  exit 1
}
(( answer_to_media_ms >= 0 && answer_to_media_ms <= MAX_ANSWER_TO_MEDIA_MS )) || {
  echo "Answer-to-protected-media readiness was ${answer_to_media_ms}ms (limit ${MAX_ANSWER_TO_MEDIA_MS}ms)." >&2
  exit 1
}

curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID/end" >/dev/null
for _ in {1..30}; do
  state="$(curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
    "$PTT_CALL_SERVER/v1/calls/$CALL_ID" | jq -r .state)"
  [[ "$state" == ended ]] && break
  sleep 1
done
[[ "$state" == ended ]] || { echo "The host end action did not terminate the call." >&2; exit 1; }
reason="$(curl -fsS -H "Authorization: Bearer $PTT_CALL_CALLER_TOKEN" \
  "$PTT_CALL_SERVER/v1/calls/$CALL_ID" | jq -r .endReason)"
[[ "$reason" == host_ended ]] || { echo "Active call ended with unexpected reason: $reason" >&2; exit 1; }

for serial in "$PTT_ANDROID_DEVICE_1" "$PTT_ANDROID_DEVICE_2"; do
  for _ in {1..30}; do
    if ! "$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE" 2>/dev/null |
      grep -q 'CallSessionService'; then
      break
    fi
    sleep 1
  done
  if "$ADB" -s "$serial" shell dumpsys activity services "$PACKAGE" 2>/dev/null |
    grep -q 'CallSessionService'; then
    echo "Call audio ownership was not released on $serial." >&2
    exit 1
  fi
done

echo "Two-device Android encrypted call passed: Core-Telecom audio activated, both endpoints stayed protected and unmuted, and remote teardown completed (invite-to-ring ${invite_to_ring_ms}ms, ring-to-answer ${ring_to_answer_ms}ms, seat-claim ${seat_claim_ms}ms, key-send ${key_send_ms}ms, remote-key ${remote_key_ms}ms, key-ack ${key_ack_ms}ms, answer-to-key-ready ${answer_to_key_ready_ms}ms, media-connect ${media_connect_ms}ms, answer-to-media ${answer_to_media_ms}ms, answer-to-active ${answer_to_active_ms}ms)."
if [[ "$SYNTHETIC_AUDIO" == 1 ]]; then
  echo "The caller emitted five debug-only post-capture 997 Hz bursts with paired 613 Hz source markers for external acoustic verification."
fi
if [[ "$REQUIRE_REAL_MIC_AUDIO" == 1 ]]; then
  echo "The call used non-synthetic WebRTC microphone capture; debug processors observed without replacing samples."
fi
