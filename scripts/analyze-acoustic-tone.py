#!/usr/bin/env python3
"""Count audible synthetic PTT bursts in a real microphone WAV recording."""

from __future__ import annotations

import argparse
import array
import json
import math
import random
import statistics
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
    peak_tone_dbfs: float
    candidate_segments: int
    longest_candidate_seconds: float


@dataclass(frozen=True)
class ToneSegment:
    start_seconds: float
    end_seconds: float


def _window_metrics(samples: array.array, sample_rate: int, frequency: float) -> tuple[float, float, float]:
    count = len(samples)
    if count == 0:
        return -120.0, 0.0, -120.0
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
    tone_dbfs = 20.0 * math.log10(max(tone_rms, 1e-6))
    return rms_dbfs, min(1.5, tone_rms / max(rms, 1e-9)), tone_dbfs


def _window_band_metrics(
    samples: array.array,
    sample_rate: int,
    frequency: float,
    tolerance_hz: float = 4.0,
) -> tuple[float, float, float]:
    """Measure a narrow tone band while tolerating real speaker/microphone clock drift."""
    offsets = (-tolerance_hz, -tolerance_hz / 2.0, 0.0, tolerance_hz / 2.0, tolerance_hz)
    measurements = [_window_metrics(samples, sample_rate, frequency + offset) for offset in offsets]
    strongest = max(measurements, key=lambda measurement: measurement[2])
    return measurements[0][0], strongest[1], strongest[2]


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
    minimum_rms_dbfs: float = -60.0,
    minimum_tone_ratio: float = 0.10,
    minimum_tone_dbfs: float = -62.0,
    minimum_burst_seconds: float = 0.30,
) -> Analysis:
    result, _ = _analyze_segments(
        recording,
        frequency=frequency,
        window_seconds=window_seconds,
        minimum_rms_dbfs=minimum_rms_dbfs,
        minimum_tone_ratio=minimum_tone_ratio,
        minimum_tone_dbfs=minimum_tone_dbfs,
        minimum_burst_seconds=minimum_burst_seconds,
    )
    return result


def _analyze_segments(
    recording: Path,
    frequency: float,
    window_seconds: float,
    minimum_rms_dbfs: float,
    minimum_tone_ratio: float,
    minimum_tone_dbfs: float,
    minimum_burst_seconds: float,
) -> tuple[Analysis, list[ToneSegment]]:
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
        peak_tone_dbfs = -120.0
        total_frames = source.getnframes()
        while True:
            payload = source.readframes(window_frames)
            if not payload:
                break
            samples = array.array("h")
            samples.frombytes(payload)
            if sys.byteorder != "little":
                samples.byteswap()
            # Hardware playback, sample-rate conversion, and an independent microphone do not
            # share a clock. A few hertz of apparent drift is normal and must not turn audible
            # output into a false zero, while the narrow band remains highly frequency-specific.
            rms_dbfs, tone_ratio, tone_dbfs = _window_band_metrics(samples, sample_rate, frequency)
            peak_rms = max(peak_rms, rms_dbfs)
            peak_ratio = max(peak_ratio, tone_ratio)
            peak_tone_dbfs = max(peak_tone_dbfs, tone_dbfs)
            active.append(
                rms_dbfs >= minimum_rms_dbfs
                and tone_ratio >= minimum_tone_ratio
                and tone_dbfs >= minimum_tone_dbfs
            )

    bridged = _bridge_short_gaps(active, max(1, round(0.20 / window_seconds)))
    minimum_windows = max(1, math.ceil(minimum_burst_seconds / window_seconds))
    bursts = 0
    active_windows = 0
    candidate_segments = 0
    longest_candidate_windows = 0
    segments: list[ToneSegment] = []
    index = 0
    while index < len(bridged):
        if not bridged[index]:
            index += 1
            continue
        start = index
        while index < len(bridged) and bridged[index]:
            index += 1
        length = index - start
        candidate_segments += 1
        longest_candidate_windows = max(longest_candidate_windows, length)
        if length >= minimum_windows:
            bursts += 1
            active_windows += length
            segments.append(
                ToneSegment(
                    start_seconds=round(start * window_seconds, 6),
                    end_seconds=round(index * window_seconds, 6),
                )
            )
    return (
        Analysis(
            bursts=bursts,
            active_seconds=round(active_windows * window_seconds, 3),
            duration_seconds=round(total_frames / sample_rate, 3),
            peak_rms_dbfs=round(peak_rms, 2),
            peak_tone_ratio=round(peak_ratio, 3),
            peak_tone_dbfs=round(peak_tone_dbfs, 2),
            candidate_segments=candidate_segments,
            longest_candidate_seconds=round(longest_candidate_windows * window_seconds, 3),
        ),
        segments,
    )


def _nearest_rank_percentile(values: list[float], percentile: float) -> float:
    if not values:
        raise ValueError("at least one latency sample is required")
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def measure_mouth_to_ear(
    recording: Path,
    source_frequency: float,
    received_frequency: float,
    expected_pairs: int,
) -> tuple[list[float], Analysis, Analysis]:
    # Twenty-millisecond windows align with the codec frame size and keep the
    # independent acoustic latency estimate precise enough for the 400 ms gate.
    source, source_segments = _analyze_segments(
        recording,
        frequency=source_frequency,
        window_seconds=0.02,
        minimum_rms_dbfs=-60.0,
        minimum_tone_ratio=0.30,
        minimum_tone_dbfs=-62.0,
        minimum_burst_seconds=0.12,
    )
    # Use the same 100 ms receiver windows as the audible-burst gate. The distant
    # receiver tone can briefly dip below the narrow-band threshold in a room
    # recording; 20 ms windows turn one real speaker burst into several fragments
    # and make those fragments look like independent transmissions. A 100 ms
    # window still gives ample precision for the 400 ms product gate while keeping
    # burst identity stable.
    received, received_segments = _analyze_segments(
        recording,
        frequency=received_frequency,
        window_seconds=0.10,
        minimum_rms_dbfs=-60.0,
        minimum_tone_ratio=0.10,
        minimum_tone_dbfs=-62.0,
        minimum_burst_seconds=0.30,
    )
    if len(source_segments) < expected_pairs:
        raise ValueError(
            f"heard {len(source_segments)} complete source markers; expected at least {expected_pairs}"
        )
    if len(received_segments) < expected_pairs:
        raise ValueError(
            f"heard {len(received_segments)} complete receiver bursts; expected at least {expected_pairs}"
        )

    latencies: list[float] = []
    source_index = 0
    last_paired_source = -1
    for receiver_segment in received_segments:
        # A focused room microphone may clearly hear the receiving phone in only
        # one direction even though source markers from both senders and the push-
        # wake phase remain audible. Pairing each source with the next receiver
        # therefore shifts the whole sequence. Instead, associate a receiver burst
        # with the most recent source marker that can have caused it.
        while (
            source_index < len(source_segments)
            and source_segments[source_index].start_seconds <= receiver_segment.start_seconds
        ):
            source_index += 1
        candidate_index = source_index - 1
        if candidate_index < 0 or candidate_index <= last_paired_source:
            continue
        source_segment = source_segments[candidate_index]
        latency_ms = (receiver_segment.start_seconds - source_segment.start_seconds) * 1_000.0
        if latency_ms > 5_000:
            continue
        latencies.append(round(latency_ms, 1))
        last_paired_source = candidate_index
    if len(latencies) < expected_pairs:
        raise ValueError(
            f"matched {len(latencies)} source-to-speaker pairs; expected at least {expected_pairs}"
        )
    return latencies, source, received


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


def _write_noisy_fixture(path: Path, frequency: float, bursts: int) -> None:
    """Model a distant phone tone mixed with louder broadband room energy."""
    sample_rate = 48_000
    samples = array.array("h")
    noise = random.Random(0x505454)

    def append(seconds: float, tone: bool) -> None:
        start = len(samples)
        for offset in range(round(sample_rate * seconds)):
            phase = 2.0 * math.pi * frequency * (start + offset) / sample_rate
            tone_sample = math.sin(phase) * 120 if tone else 0
            samples.append(int(tone_sample + noise.randint(-1_000, 1_000)))

    append(0.4, False)
    for _ in range(bursts):
        append(0.8, True)
        append(0.6, False)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples.tobytes())


def _write_latency_fixture(path: Path, pairs: int, latency_seconds: float) -> None:
    sample_rate = 48_000
    samples = array.array("h")

    def append(seconds: float, frequency: float | None) -> None:
        start = len(samples)
        for offset in range(round(sample_rate * seconds)):
            if frequency is None:
                value = 0
            else:
                phase = 2.0 * math.pi * frequency * (start + offset) / sample_rate
                value = int(math.sin(phase) * 18_000)
            samples.append(value)

    append(0.4, None)
    for _ in range(pairs):
        append(0.2, 613.0)
        append(max(0.0, latency_seconds - 0.2), None)
        append(1.0, 997.0)
        append(0.6, None)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples.tobytes())


def _write_sparse_direction_fixture(path: Path, pairs: int, latency_seconds: float) -> None:
    """Model source markers from inaudible directions before one audible direction."""
    sample_rate = 48_000
    samples = array.array("h")

    def append(seconds: float, frequency: float | None) -> None:
        start = len(samples)
        for offset in range(round(sample_rate * seconds)):
            if frequency is None:
                value = 0
            else:
                phase = 2.0 * math.pi * frequency * (start + offset) / sample_rate
                value = int(math.sin(phase) * 18_000)
            samples.append(value)

    append(0.4, None)
    for _ in range(pairs):
        append(0.2, 613.0)
        append(1.0, None)
    for _ in range(pairs):
        append(0.2, 613.0)
        append(max(0.0, latency_seconds - 0.2), None)
        append(1.0, 997.0)
        append(0.6, None)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples.tobytes())


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="ptt-acoustic-test-") as directory:
        fixture = Path(directory) / "fixture.wav"
        wrong = Path(directory) / "wrong.wav"
        noisy = Path(directory) / "noisy.wav"
        latency = Path(directory) / "latency.wav"
        slow_latency = Path(directory) / "slow-latency.wav"
        sparse_direction = Path(directory) / "sparse-direction.wav"
        _write_fixture(fixture, 997.0, 4)
        _write_fixture(wrong, 613.0, 3)
        _write_noisy_fixture(noisy, 997.0, 3)
        _write_latency_fixture(latency, 20, 0.24)
        _write_latency_fixture(slow_latency, 20, 0.44)
        _write_sparse_direction_fixture(sparse_direction, 3, 0.24)
        result = analyze(fixture)
        wrong_result = analyze(wrong)
        noisy_result = analyze(noisy)
        if result.bursts != 4 or wrong_result.bursts != 0 or noisy_result.bursts != 3:
            raise AssertionError(
                f"acoustic analyzer self-test failed: {result=} {wrong_result=} {noisy_result=}"
            )
        samples, source, received = measure_mouth_to_ear(latency, 613.0, 997.0, 20)
        p95 = _nearest_rank_percentile(samples, 0.95)
        if source.bursts != 20 or received.bursts != 20 or not 220 <= p95 <= 280:
            raise AssertionError(
                f"mouth-to-ear analyzer self-test failed: samples={samples} source={source} received={received}"
            )
        slow_samples, _, _ = measure_mouth_to_ear(slow_latency, 613.0, 997.0, 20)
        if _nearest_rank_percentile(slow_samples, 0.95) < 400:
            raise AssertionError("mouth-to-ear analyzer accepted the over-budget fixture")
        sparse_samples, sparse_source, sparse_received = measure_mouth_to_ear(
            sparse_direction, 613.0, 997.0, 3
        )
        if (
            sparse_source.bursts != 6
            or sparse_received.bursts != 3
            or _nearest_rank_percentile(sparse_samples, 0.95) >= 400
        ):
            raise AssertionError(
                "mouth-to-ear analyzer mismatched source-only directions: "
                f"samples={sparse_samples} source={sparse_source} received={sparse_received}"
            )
        print(
            "Acoustic analyzer self-test passed: audible burst discrimination and "
            f"20-pair mouth-to-ear measurement ({p95:.1f} ms p95)"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording", nargs="?", type=Path)
    parser.add_argument("--frequency", type=float, default=997.0)
    parser.add_argument("--expected-bursts", type=int)
    parser.add_argument("--maximum-bursts", type=int)
    parser.add_argument("--source-frequency", type=float)
    parser.add_argument("--max-mouth-to-ear-ms", type=float)
    parser.add_argument("--minimum-latency-pairs", type=int)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    if arguments.recording is None or arguments.expected_bursts is None:
        parser.error("recording and --expected-bursts are required")
    if arguments.expected_bursts < 1:
        parser.error("--expected-bursts must be positive")
    maximum_bursts = arguments.maximum_bursts or arguments.expected_bursts + 4
    if maximum_bursts < arguments.expected_bursts:
        parser.error("--maximum-bursts must not be less than --expected-bursts")
    result = analyze(arguments.recording, frequency=arguments.frequency)
    report: dict[str, object] = asdict(result)
    if arguments.source_frequency is not None:
        source_diagnostic = analyze(
            arguments.recording,
            frequency=arguments.source_frequency,
            window_seconds=0.02,
            minimum_burst_seconds=0.12,
            minimum_tone_ratio=0.30,
        )
        report["source_diagnostic"] = asdict(source_diagnostic)
    if result.bursts < arguments.expected_bursts:
        print(json.dumps(report, sort_keys=True), file=sys.stderr)
        print(
            f"Acoustic gate failed: heard {result.bursts} complete {arguments.frequency:g} Hz bursts; "
            f"expected at least {arguments.expected_bursts}.",
            file=sys.stderr,
        )
        return 1
    if result.bursts > maximum_bursts:
        print(json.dumps(report, sort_keys=True), file=sys.stderr)
        print(
            f"Acoustic gate failed: heard {result.bursts} bursts; declared at most "
            f"{maximum_bursts} for this campaign, so the recording is ambiguous.",
            file=sys.stderr,
        )
        return 1
    if arguments.source_frequency is not None or arguments.max_mouth_to_ear_ms is not None:
        if arguments.source_frequency is None or arguments.max_mouth_to_ear_ms is None:
            parser.error("--source-frequency and --max-mouth-to-ear-ms must be provided together")
        if arguments.max_mouth_to_ear_ms <= 0:
            parser.error("--max-mouth-to-ear-ms must be positive")
        minimum_latency_pairs = arguments.minimum_latency_pairs or arguments.expected_bursts
        if minimum_latency_pairs < 1 or minimum_latency_pairs > arguments.expected_bursts:
            parser.error("--minimum-latency-pairs must be between 1 and --expected-bursts")
        try:
            latencies, source_result, received_result = measure_mouth_to_ear(
                arguments.recording,
                arguments.source_frequency,
                arguments.frequency,
                minimum_latency_pairs,
            )
        except ValueError as error:
            print(f"Acoustic latency gate failed: {error}.", file=sys.stderr)
            return 1
        p95 = _nearest_rank_percentile(latencies, 0.95)
        report.update(
            {
                "source_markers": source_result.bursts,
                "mouth_to_ear_samples": len(latencies),
                "required_mouth_to_ear_samples": minimum_latency_pairs,
                "mouth_to_ear_median_ms": round(statistics.median(latencies), 1),
                "mouth_to_ear_p95_ms": round(p95, 1),
                "mouth_to_ear_max_ms": round(max(latencies), 1),
                "mouth_to_ear_samples_ms": latencies,
            }
        )
        if p95 >= arguments.max_mouth_to_ear_ms:
            # Promptfoo retains stderr when a native gate fails. Keep the diagnostic
            # privacy-safe (timings and levels only) so a remote failure can be
            # investigated without uploading the room recording.
            print(json.dumps(report, sort_keys=True), file=sys.stderr)
            print(
                f"Acoustic latency gate failed: mouth-to-ear p95 {p95:.1f} ms must be below "
                f"{arguments.max_mouth_to_ear_ms:g} ms.",
                file=sys.stderr,
            )
            return 1
    print(json.dumps(report, sort_keys=True))
    print(f"Acoustic gate passed: microphone heard {result.bursts} complete speaker-output bursts")
    if "mouth_to_ear_p95_ms" in report:
        print(
            "Mouth-to-ear gate passed: "
            f"{report['mouth_to_ear_samples']} acoustic pairs, p95 {report['mouth_to_ear_p95_ms']} ms"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
