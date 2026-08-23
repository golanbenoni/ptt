package app.ptt.loopback

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.signal.libsignal.protocol.IdentityKeyPair

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class LoopbackTest {
    @BeforeAll
    fun requireJni() {
        try {
            IdentityKeyPair.generate()
        } catch (e: Throwable) {
            assumeTrue(false, "libsignal JNI required: ${e.message}")
        }
    }

    @Test
    fun channelKickStopsDecrypt() {
        val r = runChannelLoopback()
        assertTrue(r.bobHeardFirst && r.carolHeardFirst)
        assertTrue(r.bobHeardAfterKick && r.carolBlockedAfterKick)
    }

    @Test
    fun encryptedToneSurvivesUdp() {
        val durationMs = 400
        val result = runLoopback(durationMs = durationMs, paceMs = 1)
        assertEquals(durationMs / FRAME_MS, result.frames)
        assertEquals(result.frames * FRAME_BYTES, result.pcm.size)
        assertTrue(result.safetyNumber.all { it.isDigit() })
        // 440 Hz should have energy, not silence
        var energy = 0L
        var i = 0
        while (i + 1 < result.pcm.size) {
            val s = (result.pcm[i].toInt() and 0xff) or (result.pcm[i + 1].toInt() shl 8)
            val signed = s.toShort().toInt()
            energy += kotlin.math.abs(signed)
            i += 2
        }
        assertTrue(energy > 1_000_000, "pcm looks silent energy=$energy")
    }
}
