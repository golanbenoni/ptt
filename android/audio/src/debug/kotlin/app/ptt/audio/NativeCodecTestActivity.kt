package app.ptt.audio

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.sin

/** Debug-only on-device smoke test proving JNI load plus Opus encode/decode/PLC. */
class NativeCodecTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = TextView(this).apply { text = "Testing native Opus…" }
        setContentView(result)
        thread(name = "ptt-native-codec-smoke") {
            val status =
                runCatching {
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
                            "PASS packet=${packet.size} bytes jitter=reorder+flush plc=ok"
                        }
                    }
                }.getOrElse { "FAIL ${it::class.java.simpleName}: ${it.message}" }
            Log.i(TAG, status)
            runOnUiThread { result.text = status }
        }
    }

    private companion object {
        const val TAG = "PTT_NATIVE_TEST"
    }
}
