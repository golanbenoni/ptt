#!/usr/bin/env python3
"""Count audible synthetic PTT bursts in a real microphone WAV recording."""

from __future__ import annotations

import argparse
import array
import json
import math
import sys
import tempfile
import wave
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class Analysis:
    bursts: int
    active_seconds: float
    duration_seconds: float
    peak_rms_dbfs: float
    peak_tone_ratio: float


def _window_metrics(samples: array.array, sample_rate: int, frequency: float) -> tuple[float, float]:
    count = len(samples)
    if count == 0:
        return -120.0, 0.0
    mean = sum(samples) / count
    square_sum = 0.0
    coefficient = 2.0 * math.cos(2.0 * math.pi * frequency / sample_rate)
    previous = 0.0
    previous_two = 0.0
    for raw in samples:
        sample = float(raw) - mean
        square_sum += sample * sample
        current = sample + coefficient * previous - previous_two
        previous_two = previous
        previous = current
    rms = math.sqrt(square_sum / count) / 32768.0
    power = max(0.0, previous * previous + previous_two * previous_two - coefficient * previous * previous_two)
    tone_peak = 2.0 * math.sqrt(power) / count / 32768.0
    tone_rms = tone_peak / math.sqrt(2.0)
    rms_dbfs = 20.0 * math.log10(max(rms, 1e-6))
    return rms_dbfs, min(1.5, tone_rms / max(rms, 1e-9))


def _bridge_short_gaps(active: list[bool], maximum_gap_windows: int) -> list[bool]:
    bridged = active.copy()
    index = 0
    while index < len(bridged):
        if bridged[index]:
            index += 1
            continue
        start = index
        while index < len(bridged) and not bridged[index]:
            index += 1
        if start > 0 and index < len(bridged) and index - start <= maximum_gap_windows:
            bridged[start:index] = [True] * (index - start)
    return bridged


def analyze(
    recording: Path,
    frequency: float = 997.0,
    window_seconds: float = 0.1,
    minimum_rms_dbfs: float = -45.0,
    minimum_tone_ratio: float = 0.30,
    minimum_burst_seconds: float = 0.45,
) -> Analysis:
    with wave.open(str(recording), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise ValueError("recording must be mono 16-bit PCM WAV")
        sample_rate = source.getframerate()
        if sample_rate < 16_000:
            raise ValueError("recording sample rate must be at least 16 kHz")
        window_frames = max(1, round(sample_rate * window_seconds))
        active: list[bool] = []
        peak_rms = -120.0
        peak_ratio = 0.0
        total_frames = source.getnframes()
        while True:
            payload = source.readframes(window_frames)
            if not payload:
                break
            samples = array.array("h")
            samples.frombytes(payload)
            if sys.byteorder != "little":
                samples.byteswap()
            rms_dbfs, tone_ratio = _window_metrics(samples, sample_rate, frequency)
            peak_rms = max(peak_rms, rms_dbfs)
            peak_ratio = max(peak_ratio, tone_ratio)
            active.append(rms_dbfs >= minimum_rms_dbfs and tone_ratio >= minimum_tone_ratio)

    bridged = _bridge_short_gaps(active, max(1, round(0.20 / window_seconds)))
    minimum_windows = max(1, math.ceil(minimum_burst_seconds / window_seconds))
    bursts = 0
    active_windows = 0
    index = 0
    while index < len(bridged):
        if not bridged[index]:
            index += 1
            continue
        start = index
        while index < len(bridged) and bridged[index]:
            index += 1
        length = index - start
        if length >= minimum_windows:
            bursts += 1
            active_windows += length
    return Analysis(
        bursts=bursts,
        active_seconds=round(active_windows * window_seconds, 3),
        duration_seconds=round(total_frames / sample_rate, 3),
        peak_rms_dbfs=round(peak_rms, 2),
        peak_tone_ratio=round(peak_ratio, 3),
    )


def _write_fixture(path: Path, frequency: float, bursts: int) -> None:
    sample_rate = 48_000
    samples = array.array("h")

    def append(seconds: float, tone: bool) -> None:
        start = len(samples)
        for offset in range(round(sample_rate * seconds)):
            if tone:
                phase = 2.0 * math.pi * frequency * (start + offset) / sample_rate
                value = int(math.sin(phase) * 18_000 + math.sin(phase * 0.31) * 700)
            else:
                value = 0
            samples.append(max(-32768, min(32767, value)))

    append(0.4, False)
    for _ in range(bursts):
        append(1.0, True)
        append(0.6, False)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples.tobytes())


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="ptt-acoustic-test-") as directory:
        fixture = Path(directory) / "fixture.wav"
        wrong = Path(directory) / "wrong.wav"
        _write_fixture(fixture, 997.0, 4)
        _write_fixture(wrong, 613.0, 3)
        result = analyze(fixture)
        wrong_result = analyze(wrong)
        if result.bursts != 4 or wrong_result.bursts != 0:
            raise AssertionError(f"acoustic analyzer self-test failed: {result=} {wrong_result=}")
        print("Acoustic analyzer self-test passed: four 997 Hz bursts detected; off-frequency audio rejected")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording", nargs="?", type=Path)
    parser.add_argument("--frequency", type=float, default=997.0)
    parser.add_argument("--expected-bursts", type=int)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    if arguments.recording is None or arguments.expected_bursts is None:
        parser.error("recording and --expected-bursts are required")
    if arguments.expected_bursts < 1:
        parser.error("--expected-bursts must be positive")
    result = analyze(arguments.recording, frequency=arguments.frequency)
    print(json.dumps(asdict(result), sort_keys=True))
    if result.bursts < arguments.expected_bursts:
        print(
            f"Acoustic gate failed: heard {result.bursts} complete {arguments.frequency:g} Hz bursts; "
            f"expected at least {arguments.expected_bursts}.",
            file=sys.stderr,
        )
        return 1
    if result.bursts > arguments.expected_bursts + 4:
        print(
            f"Acoustic gate failed: heard {result.bursts} bursts; unexpected extra tone activity makes the recording ambiguous.",
            file=sys.stderr,
        )
        return 1
    print(f"Acoustic gate passed: microphone heard {result.bursts} complete speaker-output bursts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
