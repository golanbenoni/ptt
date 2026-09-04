#!/usr/bin/env bash
# Record the four-device room output and reject internal-only playback success.
set -euo pipefail

: "${PTT_ACOUSTIC_INPUT:?PTT_ACOUSTIC_INPUT is required (AVFoundation audio input index)}"
if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 command [arguments ...]" >&2
  exit 2
fi
if ! [[ "$PTT_ACOUSTIC_INPUT" =~ ^[0-9]+$ ]]; then
  echo "PTT_ACOUSTIC_INPUT must be the numeric AVFoundation audio input index." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRANSMISSIONS="${PTT_E2E_TRANSMISSIONS:-5}"
if ! [[ "$TRANSMISSIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_E2E_TRANSMISSIONS must be a positive integer." >&2
  exit 2
fi
EXPECTED_DIRECTIONS="${PTT_ACOUSTIC_EXPECTED_DIRECTIONS:-8}"
if ! [[ "$EXPECTED_DIRECTIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_ACOUSTIC_EXPECTED_DIRECTIONS must be a positive integer." >&2
  exit 2
fi
# The complete four-device matrix has eight audible directions: two foreground
# directions per platform, one terminated-process wake direction per platform,
# and both cross-platform directions. Focused physical workflows may set a
# smaller explicit direction count while leaving the complete gate unchanged.
EXPECTED_BURSTS=$((TRANSMISSIONS * EXPECTED_DIRECTIONS))
WORK_DIR="$(mktemp -d -t ptt-acoustic.XXXXXX)"
RECORDING="${PTT_ACOUSTIC_RECORDING_PATH:-$WORK_DIR/four-device-acoustic.wav}"
FFMPEG_LOG="$WORK_DIR/ffmpeg.log"
ffmpeg_pid=""

cleanup() {
  if [[ -n "$ffmpeg_pid" ]] && kill -0 "$ffmpeg_pid" 2>/dev/null; then
    kill -INT "$ffmpeg_pid" 2>/dev/null || true
    wait "$ffmpeg_pid" 2>/dev/null || true
  fi
  if [[ -z "${PTT_ACOUSTIC_RECORDING_PATH:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

command -v ffmpeg >/dev/null || { echo "ffmpeg is required for the acoustic gate." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required for the acoustic gate." >&2; exit 1; }
mkdir -p "$(dirname "$RECORDING")"

echo "Starting privacy-local acoustic capture from AVFoundation input $PTT_ACOUSTIC_INPUT"
ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation \
  -thread_queue_size 512 -i ":$PTT_ACOUSTIC_INPUT" -ac 1 -ar 48000 \
  -c:a pcm_s16le -y "$RECORDING" >"$FFMPEG_LOG" 2>&1 &
ffmpeg_pid=$!
sleep 2
if ! kill -0 "$ffmpeg_pid" 2>/dev/null; then
  wait "$ffmpeg_pid" 2>/dev/null || true
  echo "Acoustic capture could not start. Available AVFoundation inputs:" >&2
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/AVFoundation audio devices:/,$p' >&2 || true
  sed -n '1,80p' "$FFMPEG_LOG" >&2
  exit 1
fi

set +e
"$@"
command_status=$?
set -e
kill -INT "$ffmpeg_pid" 2>/dev/null || true
wait "$ffmpeg_pid" 2>/dev/null || true
ffmpeg_pid=""
if [[ "$command_status" -ne 0 ]]; then
  echo "Physical product matrix failed before acoustic analysis." >&2
  exit "$command_status"
fi
test -s "$RECORDING" || { echo "Acoustic capture produced no WAV data." >&2; exit 1; }
python3 "$ROOT/scripts/analyze-acoustic-tone.py" "$RECORDING" \
  --frequency 997 --expected-bursts "$EXPECTED_BURSTS" \
  --source-frequency 613 --max-mouth-to-ear-ms "${PTT_E2E_MAX_MOUTH_TO_EAR_MS:-400}"
echo "External acoustic and mouth-to-ear latency proof passed; the temporary room recording will not be uploaded."
