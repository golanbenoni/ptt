#!/usr/bin/env bash
# Run repeated encrypted Android calls against one already-running disposable
# control/media stack. Directions alternate so both physical devices exercise
# caller and callee ownership without rebuilding the application between calls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SINGLE_CALL_DRIVER="$ROOT/scripts/test-android-two-device-calls.sh"
ITERATIONS="${PTT_CALL_ITERATIONS:-20}"
MAX_INVITE_TO_RING_MS="${PTT_CALL_MAX_INVITE_TO_RING_MS:-5000}"
MAX_ANSWER_TO_MEDIA_MS="${PTT_CALL_MAX_ANSWER_TO_MEDIA_MS:-2000}"

: "${PTT_ANDROID_DEVICE_1:?PTT_ANDROID_DEVICE_1 is required}"
: "${PTT_ANDROID_DEVICE_2:?PTT_ANDROID_DEVICE_2 is required}"
: "${PTT_CALL_CALLER_ACI:?PTT_CALL_CALLER_ACI is required}"
: "${PTT_CALL_CALLER_MAILBOX:?PTT_CALL_CALLER_MAILBOX is required}"
: "${PTT_CALL_CALLER_TOKEN:?PTT_CALL_CALLER_TOKEN is required}"
: "${PTT_CALL_CALLER_IDENTITY_FIXTURE:?PTT_CALL_CALLER_IDENTITY_FIXTURE is required}"
: "${PTT_CALL_CALLEE_ACI:?PTT_CALL_CALLEE_ACI is required}"
: "${PTT_CALL_CALLEE_MAILBOX:?PTT_CALL_CALLEE_MAILBOX is required}"
: "${PTT_CALL_CALLEE_TOKEN:?PTT_CALL_CALLEE_TOKEN is required}"
: "${PTT_CALL_CALLEE_IDENTITY_FIXTURE:?PTT_CALL_CALLEE_IDENTITY_FIXTURE is required}"

if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || (( ITERATIONS > 50 )); then
  echo "PTT_CALL_ITERATIONS must be between 1 and 50." >&2
  exit 1
fi
[[ "$MAX_INVITE_TO_RING_MS" =~ ^[1-9][0-9]*$ &&
   "$MAX_ANSWER_TO_MEDIA_MS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Repeated-call latency limits must be positive integers." >&2
  exit 1
}
[[ "$PTT_ANDROID_DEVICE_1" != "$PTT_ANDROID_DEVICE_2" ]] || {
  echo "Repeated calls require two distinct Android devices." >&2
  exit 1
}

DEVICE_A="$PTT_ANDROID_DEVICE_1"
DEVICE_B="$PTT_ANDROID_DEVICE_2"
ACI_A="$PTT_CALL_CALLER_ACI"
MAILBOX_A="$PTT_CALL_CALLER_MAILBOX"
TOKEN_A="$PTT_CALL_CALLER_TOKEN"
IDENTITY_A="$PTT_CALL_CALLER_IDENTITY_FIXTURE"
DEVICE_ID_A="${PTT_CALL_CALLER_DEVICE_ID:-1}"
ACI_B="$PTT_CALL_CALLEE_ACI"
MAILBOX_B="$PTT_CALL_CALLEE_MAILBOX"
TOKEN_B="$PTT_CALL_CALLEE_TOKEN"
IDENTITY_B="$PTT_CALL_CALLEE_IDENTITY_FIXTURE"
DEVICE_ID_B="${PTT_CALL_CALLEE_DEVICE_ID:-1}"
WORK_DIR="$(mktemp -d -t ptt-android-repeated-calls.XXXXXX)"
INVITE_SAMPLES=""
MEDIA_SAMPLES=""

cleanup() {
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

append_sample() {
  local existing="$1" sample="$2"
  if [[ -n "$existing" ]]; then printf '%s,%s' "$existing" "$sample"
  else printf '%s' "$sample"
  fi
}

run_direction() {
  local iteration="$1" label="$2" caller_device="$3" callee_device="$4"
  local caller_aci="$5" caller_mailbox="$6" caller_token="$7" caller_identity="$8"
  local caller_device_id="$9" callee_aci="${10}" callee_mailbox="${11}"
  local callee_token="${12}" callee_identity="${13}" callee_device_id="${14}"
  local install_mode=1 output invite_sample media_sample
  if (( iteration == 1 )); then install_mode=0; fi
  output="$WORK_DIR/call-$iteration.log"

  echo "Repeated encrypted call $iteration/$ITERATIONS ($label)"
  PTT_ANDROID_DEVICE_1="$caller_device" \
  PTT_ANDROID_DEVICE_2="$callee_device" \
  PTT_CALL_CALLER_ACI="$caller_aci" \
  PTT_CALL_CALLER_MAILBOX="$caller_mailbox" \
  PTT_CALL_CALLER_TOKEN="$caller_token" \
  PTT_CALL_CALLER_IDENTITY_FIXTURE="$caller_identity" \
  PTT_CALL_CALLER_DEVICE_ID="$caller_device_id" \
  PTT_CALL_CALLEE_ACI="$callee_aci" \
  PTT_CALL_CALLEE_MAILBOX="$callee_mailbox" \
  PTT_CALL_CALLEE_TOKEN="$callee_token" \
  PTT_CALL_CALLEE_IDENTITY_FIXTURE="$callee_identity" \
  PTT_CALL_CALLEE_DEVICE_ID="$callee_device_id" \
  PTT_ANDROID_SKIP_INSTALL="$install_mode" \
    "$SINGLE_CALL_DRIVER" | tee "$output"

  invite_sample="$(sed -nE 's/.*invite-to-ring ([0-9]+)ms.*/\1/p' "$output" | tail -1)"
  media_sample="$(sed -nE 's/.*answer-to-media ([0-9]+)ms.*/\1/p' "$output" | tail -1)"
  [[ "$invite_sample" =~ ^[0-9]+$ && "$media_sample" =~ ^[0-9]+$ ]] || {
    echo "Repeated call $iteration did not emit both required latency samples." >&2
    exit 1
  }
  INVITE_SAMPLES="$(append_sample "$INVITE_SAMPLES" "$invite_sample")"
  MEDIA_SAMPLES="$(append_sample "$MEDIA_SAMPLES" "$media_sample")"
}

for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  if (( iteration % 2 == 1 )); then
    run_direction "$iteration" "A to B" \
      "$DEVICE_A" "$DEVICE_B" "$ACI_A" "$MAILBOX_A" "$TOKEN_A" "$IDENTITY_A" "$DEVICE_ID_A" \
      "$ACI_B" "$MAILBOX_B" "$TOKEN_B" "$IDENTITY_B" "$DEVICE_ID_B"
  else
    run_direction "$iteration" "B to A" \
      "$DEVICE_B" "$DEVICE_A" "$ACI_B" "$MAILBOX_B" "$TOKEN_B" "$IDENTITY_B" "$DEVICE_ID_B" \
      "$ACI_A" "$MAILBOX_A" "$TOKEN_A" "$IDENTITY_A" "$DEVICE_ID_A"
  fi
done

"$ROOT/scripts/assert-latency-samples.sh" \
  "Repeated Android invite-to-ring" "$INVITE_SAMPLES" "$ITERATIONS" "$MAX_INVITE_TO_RING_MS"
"$ROOT/scripts/assert-latency-samples.sh" \
  "Repeated Android answer-to-media" "$MEDIA_SAMPLES" "$ITERATIONS" "$MAX_ANSWER_TO_MEDIA_MS"
echo "$ITERATIONS alternating encrypted Android calls passed with exact latency sample counts."
