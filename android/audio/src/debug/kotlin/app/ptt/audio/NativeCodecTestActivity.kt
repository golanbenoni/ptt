package app.ptt.audio

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.sin

/** Debug-only on-device smoke test proving JNI, capture, playback, Opus, jitter, and PLC. */
class NativeCodecTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = TextView(this).apply { text = "Testing native Opus…" }
        setContentView(result)
        thread(name = "ptt-native-codec-smoke") {
            val status =
                runCatching {
                    val audioResult = testPhysicalAudioRoute()
                    val pcm =
                        ShortArray(VOICE_SAMPLES_PER_FRAME) { index ->
                            (sin(index * 2.0 * PI * 440.0 / VOICE_SAMPLE_RATE) * 12_000.0).toInt().toShort()
                        }
                    NativeOpusEncoder().use { encoder ->
                        NativeOpusDecoder().use { decoder ->
                            val packet = encoder.encode(pcm)
                            check(packet.isNotEmpty() && packet.size <= 98) { "invalid Opus packet length" }
                            check(decoder.decode(packet).size == VOICE_SAMPLES_PER_FRAME) { "invalid decoded frame" }
                            check(decoder.decode(null).size == VOICE_SAMPLES_PER_FRAME) { "invalid PLC frame" }
                            NativeAdaptiveJitterBuffer().use { jitter ->
                                jitter.push(10, 0, 50, byteArrayOf(10))
                                jitter.push(12, 40, 100, byteArrayOf(12))
                                jitter.push(11, 20, 72, byteArrayOf(11))
                                check((jitter.pop() as JitterPlayout.Packet).bytes.contentEquals(byteArrayOf(10)))
                                check((jitter.pop() as JitterPlayout.Packet).bytes.contentEquals(byteArrayOf(11)))
                                check((jitter.pop() as JitterPlayout.Packet).bytes.contentEquals(byteArrayOf(12)))
                            }
                            NativeAdaptiveJitterBuffer().use { jitter ->
                                jitter.push(5, 0, 10, byteArrayOf(5))
                                check(jitter.pop() == JitterPlayout.Buffering)
                                jitter.flush()
                                check((jitter.pop() as JitterPlayout.Packet).bytes.contentEquals(byteArrayOf(5)))
                            }
                            "PASS $audioResult packet=${packet.size} bytes jitter=reorder+flush plc=ok"
                        }
                    }
                }.getOrElse { "FAIL ${it::class.java.simpleName}: ${it.message}" }
            Log.i(TAG, status)
            runOnUiThread { result.text = status }
        }
    }

    private fun testPhysicalAudioRoute(): String {
        val engine = AndroidAudioEngine(this)
        return try {
            val captureFrames = AtomicInteger()
            val captured = CountDownLatch(AUDIO_CAPTURE_FRAMES)
            engine.startCapture { _, _ ->
                if (captureFrames.incrementAndGet() <= AUDIO_CAPTURE_FRAMES) captured.countDown()
            }
            check(captured.await(AUDIO_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                "microphone did not provide $AUDIO_CAPTURE_FRAMES frames"
            }

            var sampleOffset = 0
            var playbackTarget = 0L
            val playbackStartedAt = System.nanoTime()
            repeat(AUDIO_PLAYBACK_FRAMES) {
                val frame =
                    ShortArray(VOICE_SAMPLES_PER_FRAME) { sampleIndex ->
                        val phase =
                            (sampleOffset + sampleIndex).toDouble() *
                                2.0 * PI * AUDIO_TEST_HZ / VOICE_SAMPLE_RATE
                        (sin(phase) * 8_000.0).toInt().toShort()
                    }
                sampleOffset += VOICE_SAMPLES_PER_FRAME
                playbackTarget = engine.play(frame)
            }
            check(engine.awaitPlayback(playbackTarget)) { "speaker playback head did not advance" }
            val playbackElapsedMs = (System.nanoTime() - playbackStartedAt) / 1_000_000
            "capture=${captureFrames.get()}frames playback=${AUDIO_PLAYBACK_FRAMES}frames " +
                "elapsed=${playbackElapsedMs}ms ${engine.playbackDiagnostics()}"
        } finally {
            engine.close()
        }
    }

    private companion object {
        const val TAG = "PTT_NATIVE_TEST"
        const val AUDIO_CAPTURE_FRAMES = 5
        const val AUDIO_PLAYBACK_FRAMES = 10
        const val AUDIO_TIMEOUT_SECONDS = 3L
        const val AUDIO_TEST_HZ = 440.0
    }
}
