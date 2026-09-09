#!/usr/bin/env bash
# Play five deterministic tones from the host's selected audio output. A physical
# sender placed by that output must capture them through its real microphone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOLUME="${PTT_CALL_STIMULUS_VOLUME:-1.0}"
WORK_DIR="$(mktemp -d -t ptt-call-microphone-fixture.XXXXXX)"
FIXTURE="$WORK_DIR/five-tone-bursts.wav"

cleanup() {
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for command in ffmpeg afplay python3; do
  command -v "$command" >/dev/null || {
    echo "Missing real-microphone stimulus dependency: $command" >&2
    exit 1
  }
done
[[ "$VOLUME" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || {
  echo "PTT_CALL_STIMULUS_VOLUME must be between 0 and 1." >&2
  exit 1
}

ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
  -i "aevalsrc='if(lt(mod(t,2.2),1),0.55*sin(2*PI*997*t),0)':s=48000:d=11" \
  -ac 1 -ar 48000 -c:a pcm_s16le -y "$FIXTURE"
python3 "$ROOT/scripts/analyze-acoustic-tone.py" "$FIXTURE" \
  --frequency 997 --expected-bursts 5 --maximum-bursts 5 >/dev/null

echo "Playing five physical 997 Hz microphone stimuli from the host audio output."
afplay -v "$VOLUME" "$FIXTURE"
