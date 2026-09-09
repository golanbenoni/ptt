#!/usr/bin/env bash
# Play five deterministic tones from the host's selected audio output. A physical
# sender placed by that output must capture them through its real microphone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOLUME="${PTT_CALL_STIMULUS_VOLUME:-1.0}"
MINIMUM_OUTPUT_VOLUME="${PTT_CALL_STIMULUS_MINIMUM_OUTPUT_VOLUME:-80}"
WORK_DIR="$(mktemp -d -t ptt-call-microphone-fixture.XXXXXX)"
FIXTURE="$WORK_DIR/five-tone-bursts.wav"
ORIGINAL_OUTPUT_VOLUME=""
ORIGINAL_OUTPUT_MUTED=""

cleanup() {
  if [[ "$ORIGINAL_OUTPUT_VOLUME" =~ ^[0-9]+$ &&
        "$ORIGINAL_OUTPUT_MUTED" =~ ^(true|false)$ ]]; then
    osascript \
      -e "set volume output volume $ORIGINAL_OUTPUT_VOLUME" \
      -e "set volume output muted $ORIGINAL_OUTPUT_MUTED" \
      >/dev/null 2>&1 || true
  fi
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for command in ffmpeg afplay osascript python3; do
  command -v "$command" >/dev/null || {
    echo "Missing real-microphone stimulus dependency: $command" >&2
    exit 1
  }
done
[[ "$VOLUME" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || {
  echo "PTT_CALL_STIMULUS_VOLUME must be between 0 and 1." >&2
  exit 1
}
if [[ ! "$MINIMUM_OUTPUT_VOLUME" =~ ^[0-9]+$ ]] ||
  (( MINIMUM_OUTPUT_VOLUME < 1 || MINIMUM_OUTPUT_VOLUME > 100 )); then
  echo "PTT_CALL_STIMULUS_MINIMUM_OUTPUT_VOLUME must be between 1 and 100." >&2
  exit 1
fi

ORIGINAL_OUTPUT_VOLUME="$(osascript -e 'output volume of (get volume settings)')"
ORIGINAL_OUTPUT_MUTED="$(osascript -e 'output muted of (get volume settings)')"
[[ "$ORIGINAL_OUTPUT_VOLUME" =~ ^[0-9]+$ &&
   "$ORIGINAL_OUTPUT_MUTED" =~ ^(true|false)$ ]] || {
  echo "Could not read the host output volume for the physical microphone fixture." >&2
  exit 1
}
if (( ORIGINAL_OUTPUT_VOLUME < MINIMUM_OUTPUT_VOLUME )) ||
  [[ "$ORIGINAL_OUTPUT_MUTED" == true ]]; then
  osascript \
    -e "set volume output volume $MINIMUM_OUTPUT_VOLUME" \
    -e 'set volume output muted false' \
    >/dev/null
fi

ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
  -i "aevalsrc='if(gte(t,2)*lt(mod(t-2,3),1),0.55*sin(2*PI*997*t),0)':s=48000:d=17" \
  -ac 1 -ar 48000 -c:a pcm_s16le -y "$FIXTURE"
python3 "$ROOT/scripts/analyze-acoustic-tone.py" "$FIXTURE" \
  --frequency 997 --expected-bursts 5 --maximum-bursts 5 >/dev/null

echo "Playing five physical 997 Hz microphone stimuli from the host audio output at no less than ${MINIMUM_OUTPUT_VOLUME}% system volume."
afplay -v "$VOLUME" "$FIXTURE"
