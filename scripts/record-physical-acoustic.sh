#!/usr/bin/env bash
# Record the four-device room output and reject internal-only playback success.
set -euo pipefail

: "${PTT_ACOUSTIC_INPUT:?PTT_ACOUSTIC_INPUT is required (AVFoundation audio input index or exact device name)}"
if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 command [arguments ...]" >&2
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
MAXIMUM_DIRECTIONS="${PTT_ACOUSTIC_MAXIMUM_DIRECTIONS:-$EXPECTED_DIRECTIONS}"
if ! [[ "$MAXIMUM_DIRECTIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "PTT_ACOUSTIC_MAXIMUM_DIRECTIONS must be a positive integer." >&2
  exit 2
fi
if (( MAXIMUM_DIRECTIONS < EXPECTED_DIRECTIONS )); then
  echo "PTT_ACOUSTIC_MAXIMUM_DIRECTIONS must not be less than PTT_ACOUSTIC_EXPECTED_DIRECTIONS." >&2
  exit 2
fi
# The complete four-device matrix has eight audible directions: two foreground
# directions per platform, one terminated-process wake direction per platform,
# and both cross-platform directions. Focused physical workflows may set a
# smaller explicit direction count while leaving the complete gate unchanged.
EXPECTED_BURSTS=$((TRANSMISSIONS * EXPECTED_DIRECTIONS))
# Some focused workflows require one complete room-audible direction while their
# strict in-app matrix exercises additional directions or lifecycle phases. Allow
# only the declared number of known phases, plus the analyzer's four-segment
# tolerance, so those successful transmissions are not mistaken for interference.
MAXIMUM_BURSTS=$((TRANSMISSIONS * MAXIMUM_DIRECTIONS + 4))
# A fixed room microphone must hear every required burst for one or more complete
# directions. Short local source chirps are easier to shadow than receiver speech,
# so latency statistics require an 80% paired sample while the in-app hardware-head
# gate still validates every transmission independently.
MINIMUM_LATENCY_PAIRS=$((EXPECTED_BURSTS * 4 / 5))
if (( MINIMUM_LATENCY_PAIRS < 1 )); then MINIMUM_LATENCY_PAIRS=1; fi
WORK_DIR="$(mktemp -d -t ptt-acoustic.XXXXXX)"
RECORDING="${PTT_ACOUSTIC_RECORDING_PATH:-$WORK_DIR/four-device-acoustic.wav}"
FFMPEG_LOG="$WORK_DIR/ffmpeg.log"
INPUT_CHECK="$WORK_DIR/input-check.wav"
INPUT_CHECK_TONE="$WORK_DIR/input-check-tone.wav"
ffmpeg_pid=""
preflight_player_pid=""

cleanup() {
  if [[ -n "$preflight_player_pid" ]] && kill -0 "$preflight_player_pid" 2>/dev/null; then
    kill "$preflight_player_pid" 2>/dev/null || true
    wait "$preflight_player_pid" 2>/dev/null || true
  fi
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
command -v afplay >/dev/null || { echo "afplay is required for the acoustic input calibration." >&2; exit 1; }
mkdir -p "$(dirname "$RECORDING")"

ACOUSTIC_INPUT_INDEX="$PTT_ACOUSTIC_INPUT"
if ! [[ "$ACOUSTIC_INPUT_INDEX" =~ ^[0-9]+$ ]]; then
  DEVICE_LIST="$WORK_DIR/avfoundation-inputs.log"
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" > /dev/null 2>"$DEVICE_LIST" || true
  ACOUSTIC_INPUT_INDEX="$(awk -v wanted="$PTT_ACOUSTIC_INPUT" '
    match($0, /\[[0-9]+\]/) {
      index_value = substr($0, RSTART + 1, RLENGTH - 2)
      device_name = substr($0, RSTART + RLENGTH)
      sub(/^[[:space:]]+/, "", device_name)
      if (device_name == wanted) print index_value
    }
  ' "$DEVICE_LIST")"
  if ! [[ "$ACOUSTIC_INPUT_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Could not resolve one exact AVFoundation audio input named '$PTT_ACOUSTIC_INPUT'. Available inputs:" >&2
    sed -n '/AVFoundation audio devices:/,$p' "$DEVICE_LIST" >&2
    exit 1
  fi
fi

echo "Verifying AVFoundation input $ACOUSTIC_INPUT_INDEX ($PTT_ACOUSTIC_INPUT) is producing live samples"
# A quiet test room is not proof that an input is disconnected, and USB display
# microphones can briefly resume as a stream of zeroes after a long product run.
# Play a short, non-speech calibration tone through the host's default output (the
# paired room display in the physical lane), then reopen the named input up to three
# times. The recording stays local and is deleted with the rest of the acoustic data.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
  -i "sine=frequency=731:duration=1" -ac 2 -ar 48000 \
  -c:a pcm_s16le -y "$INPUT_CHECK_TONE"
preflight_ok=false
for preflight_attempt in 1 2 3; do
  (sleep 0.4; exec afplay -v 1.0 "$INPUT_CHECK_TONE") &
  preflight_player_pid=$!
  preflight_recorded=false
  if ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation \
    -thread_queue_size 512 -i ":$ACOUSTIC_INPUT_INDEX" -t 2 -ac 1 -ar 48000 \
    -c:a pcm_s16le -y "$INPUT_CHECK" >"$FFMPEG_LOG" 2>&1; then
    preflight_recorded=true
  fi
  wait "$preflight_player_pid" 2>/dev/null || true
  preflight_player_pid=""
  if [[ "$preflight_recorded" == true ]] && python3 - "$INPUT_CHECK" "$preflight_attempt" <<'PY'
import math
import sys
import wave

with wave.open(sys.argv[1], "rb") as recording:
    width = recording.getsampwidth()
    rate = recording.getframerate()
    frames = recording.readframes(recording.getnframes())

if width != 2:
    raise SystemExit(f"Acoustic input preflight returned unsupported {width * 8}-bit samples.")

samples = [int.from_bytes(frames[index:index + 2], "little", signed=True)
           for index in range(0, len(frames) - 1, 2)]
peak = max((abs(sample) for sample in samples), default=0)
window = samples[int(rate * 0.45):int(rate * 1.25)]
if not window:
    raise SystemExit("Acoustic input preflight returned no calibration samples.")
cosine = sum(sample * math.cos(2 * math.pi * 731 * index / rate)
             for index, sample in enumerate(window))
sine = sum(sample * math.sin(2 * math.pi * 731 * index / rate)
           for index, sample in enumerate(window))
tone_amplitude = 2 * math.hypot(cosine, sine) / len(window)
rms = math.sqrt(sum(sample * sample for sample in window) / len(window))
tone_ratio = tone_amplitude / (rms * math.sqrt(2)) if rms else 0
if peak <= 16 or tone_amplitude < 24 or tone_ratio < 0.12:
    raise SystemExit(
        f"Acoustic input calibration attempt {sys.argv[2]} was silent or did not hear "
        f"the host tone (peak={peak}, tone={tone_amplitude:.1f}, ratio={tone_ratio:.3f})."
    )
print(
    f"Acoustic input preflight passed on attempt {sys.argv[2]} with peak "
    f"{peak}/32767 and calibration ratio {tone_ratio:.3f}"
)
PY
  then
    preflight_ok=true
    break
  fi
  sleep 1
done
if [[ "$preflight_ok" != true ]]; then
  echo "Acoustic input preflight could not verify live capture from '$PTT_ACOUSTIC_INPUT' after three attempts." >&2
  sed -n '1,80p' "$FFMPEG_LOG" >&2
  exit 1
fi

echo "Starting privacy-local acoustic capture from AVFoundation input $ACOUSTIC_INPUT_INDEX ($PTT_ACOUSTIC_INPUT)"
ffmpeg -nostdin -hide_banner -loglevel error -f avfoundation \
  -thread_queue_size 512 -i ":$ACOUSTIC_INPUT_INDEX" -ac 1 -ar 48000 \
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
  --maximum-bursts "$MAXIMUM_BURSTS" \
  --source-frequency 613 --max-mouth-to-ear-ms "${PTT_E2E_MAX_MOUTH_TO_EAR_MS:-400}" \
  --minimum-latency-pairs "$MINIMUM_LATENCY_PAIRS"
echo "External acoustic and mouth-to-ear latency proof passed; the temporary room recording will not be uploaded."
