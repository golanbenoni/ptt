#!/usr/bin/env bash
# Run a physical product command while a separate ChromeOS microphone records room audio.
set -euo pipefail

: "${PTT_CHROMEBOOK_WITNESS_HOST:?PTT_CHROMEBOOK_WITNESS_HOST is required}"
[[ $# -gt 0 ]] || { echo "Usage: $0 command [arguments ...]" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PTT_CHROMEBOOK_WITNESS_PORT:-2222}"
KEY="${PTT_CHROMEBOOK_WITNESS_KEY:-$HOME/.ssh/chromeos_brya_ed25519}"
KNOWN_HOSTS="${PTT_CHROMEBOOK_WITNESS_KNOWN_HOSTS:-$HOME/.ssh/chromeos_brya_known_hosts}"
REMOTE="${PTT_CHROMEBOOK_WITNESS_USER:-root}@${PTT_CHROMEBOOK_WITNESS_HOST}"
PCM="${PTT_CHROMEBOOK_WITNESS_PCM:-hw:0,99}"
MIC_CHANNEL="${PTT_CHROMEBOOK_WITNESS_CHANNEL:-1}"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
EXPECTED_DIRECTIONS="${PTT_ACOUSTIC_EXPECTED_DIRECTIONS:-8}"
MAXIMUM_DIRECTIONS="${PTT_ACOUSTIC_MAXIMUM_DIRECTIONS:-$EXPECTED_DIRECTIONS}"
EXPECTED_BURSTS=$((TRANSMISSIONS * EXPECTED_DIRECTIONS))
MAXIMUM_BURSTS=$((TRANSMISSIONS * MAXIMUM_DIRECTIONS + 4))
MINIMUM_PAIRS=$((EXPECTED_BURSTS * 4 / 5))
(( MINIMUM_PAIRS > 0 )) || MINIMUM_PAIRS=1

WORK_DIR="$(mktemp -d -t ptt-chromebook-witness.XXXXXX)"
RUN_ID="ptt-witness-$(date +%s)-$$"
REMOTE_RECORDING="/tmp/$RUN_ID.wav"
REMOTE_LOG="/tmp/$RUN_ID.log"
RAW_LOCAL_RECORDING="$WORK_DIR/chromebook-witness-raw.wav"
LOCAL_RECORDING="$WORK_DIR/chromebook-witness.wav"
CALIBRATION_TONE="$WORK_DIR/calibration.wav"
RAW_CALIBRATION_RECORDING="$WORK_DIR/calibration-recording-raw.wav"
CALIBRATION_RECORDING="$WORK_DIR/calibration-recording.wav"
REMOTE_PID=""
ORIGINAL_VOLUME=""
SSH=(ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=8 \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" "$REMOTE")

restore() {
  if [[ -n "$REMOTE_PID" ]]; then
    "${SSH[@]}" "kill -INT '$REMOTE_PID' 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
  "${SSH[@]}" "rm -f '$REMOTE_RECORDING' '$REMOTE_LOG'" >/dev/null 2>&1 || true
  if [[ -n "$ORIGINAL_VOLUME" ]]; then
    osascript -e "set volume output volume $ORIGINAL_VOLUME" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap restore EXIT INT TERM

for value in "$TRANSMISSIONS" "$EXPECTED_DIRECTIONS" "$MAXIMUM_DIRECTIONS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Acoustic counts must be positive integers." >&2; exit 2; }
done
[[ "$MIC_CHANNEL" =~ ^[12]$ ]] || {
  echo "PTT_CHROMEBOOK_WITNESS_CHANNEL must select physical DMIC channel 1 or 2." >&2
  exit 2
}
(( MAXIMUM_DIRECTIONS >= EXPECTED_DIRECTIONS )) || {
  echo "PTT_ACOUSTIC_MAXIMUM_DIRECTIONS must not be below the expected count." >&2
  exit 2
}
[[ -f "$KEY" && -f "$KNOWN_HOSTS" ]] || { echo "ChromeOS witness SSH identity is unavailable." >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required." >&2; exit 1; }
command -v afplay >/dev/null || { echo "afplay is required." >&2; exit 1; }
"${SSH[@]}" "command -v arecord >/dev/null && test -r /proc/asound/cards"

fetch_recording() {
  local remote_path="$1" local_path="$2"
  "${SSH[@]}" "base64 '$remote_path'" | base64 -d >"$local_path"
  test -s "$local_path" || { echo "ChromeOS witness returned no audio." >&2; exit 1; }
}

extract_microphone_channel() {
  local raw_path="$1" mono_path="$2" channel_index=$((MIC_CHANNEL - 1))
  # PCM 0,99 is a four-channel S32_LE DMIC. Channels 1 and 2 are the physical
  # microphones; channels 3 and 4 carry a large DC-like signal on this witness.
  # Asking ALSA's plug layer for mono mixes that invalid signal into the evidence.
  # Capture the native stream and explicitly select one physical microphone for
  # both calibration and product analysis instead.
  ffmpeg -nostdin -hide_banner -loglevel error -i "$raw_path" \
    -af "pan=mono|c0=c${channel_index}" -ar 48000 -c:a pcm_s16le -y "$mono_path"
  test -s "$mono_path" || { echo "ChromeOS witness channel extraction failed." >&2; exit 1; }
}

# This is the only host-generated sound. It proves that the remote microphone is
# acoustically coupled to the room before any product result can be accepted.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
  -i "aevalsrc='0.95*sin(2*PI*731*t)':s=48000:d=1" -ac 2 -ar 48000 \
  -c:a pcm_s16le -y "$CALIBRATION_TONE"
ORIGINAL_VOLUME="$(osascript -e 'output volume of (get volume settings)')"
osascript -e 'set volume output volume 100' >/dev/null
"${SSH[@]}" "rm -f '$REMOTE_RECORDING'; arecord -q -D '$PCM' -f S32_LE -r 48000 -c 4 -d 3 '$REMOTE_RECORDING'" &
CALIBRATION_SSH_PID=$!
sleep 0.8
afplay -v 1.0 "$CALIBRATION_TONE"
wait "$CALIBRATION_SSH_PID"
fetch_recording "$REMOTE_RECORDING" "$RAW_CALIBRATION_RECORDING"
extract_microphone_channel "$RAW_CALIBRATION_RECORDING" "$CALIBRATION_RECORDING"
python3 "$ROOT/scripts/analyze-acoustic-tone.py" "$CALIBRATION_RECORDING" \
  --frequency 731 --expected-bursts 1 --maximum-bursts 1 >/dev/null
osascript -e "set volume output volume $ORIGINAL_VOLUME" >/dev/null
ORIGINAL_VOLUME=""
echo "ChromeOS room-microphone calibration passed."
if [[ "${PTT_CHROMEBOOK_WITNESS_CALIBRATE_ONLY:-0}" == "1" ]]; then
  exit 0
fi

REMOTE_PID="$("${SSH[@]}" "rm -f '$REMOTE_RECORDING' '$REMOTE_LOG'; nohup arecord -q -D '$PCM' -f S32_LE -r 48000 -c 4 '$REMOTE_RECORDING' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$!")"
[[ "$REMOTE_PID" =~ ^[1-9][0-9]*$ ]] || { echo "ChromeOS witness did not return a recorder PID." >&2; exit 1; }
sleep 1
"${SSH[@]}" "kill -0 '$REMOTE_PID'"

set +e
"$@"
COMMAND_STATUS=$?
set -e

"${SSH[@]}" "kill -INT '$REMOTE_PID'; for n in 1 2 3 4 5 6 7 8 9 10; do kill -0 '$REMOTE_PID' 2>/dev/null || exit 0; sleep 0.2; done; kill -TERM '$REMOTE_PID' 2>/dev/null || true"
REMOTE_PID=""
if [[ "$COMMAND_STATUS" -ne 0 ]]; then
  echo "Physical product matrix failed before ChromeOS acoustic analysis." >&2
  exit "$COMMAND_STATUS"
fi

fetch_recording "$REMOTE_RECORDING" "$RAW_LOCAL_RECORDING"
extract_microphone_channel "$RAW_LOCAL_RECORDING" "$LOCAL_RECORDING"
ANALYSIS_OUTPUT="$WORK_DIR/analysis.txt"
python3 "$ROOT/scripts/analyze-acoustic-tone.py" "$LOCAL_RECORDING" \
  --frequency 997 --expected-bursts "$EXPECTED_BURSTS" --maximum-bursts "$MAXIMUM_BURSTS" \
  --source-frequency 613 --max-mouth-to-ear-ms "${PTT_E2E_MAX_MOUTH_TO_EAR_MS:-400}" \
  --minimum-latency-pairs "$MINIMUM_PAIRS" | tee "$ANALYSIS_OUTPUT"

SUMMARY_PATH="${PTT_CHROMEBOOK_WITNESS_SUMMARY_PATH:-}"
if [[ -n "$SUMMARY_PATH" ]]; then
  mkdir -p "$(dirname "$SUMMARY_PATH")"
  SUMMARY_JSON="$(sed -n '1p' "$ANALYSIS_OUTPUT")"
  RECORDING_SHA="$(shasum -a 256 "$RAW_LOCAL_RECORDING" | awk '{print $1}')"
  jq -n --argjson analysis "$SUMMARY_JSON" --arg sha "$RECORDING_SHA" \
    --arg model "Google-Osiris-rev3" --argjson channel "$MIC_CHANNEL" \
    '{result:"pass", witnessType:"independent-chromeos-room-microphone", witnessModel:$model, recordingSha256:$sha, analyzedPhysicalMicChannel:$channel, analysis:$analysis}' \
    >"$SUMMARY_PATH"
fi
echo "Independent ChromeOS acoustic witness gate passed; raw room audio was deleted locally."
