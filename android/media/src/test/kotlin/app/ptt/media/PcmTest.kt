package app.ptt.media

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PcmTest {
    @Test
    fun generatedToneMatchesPlaybackFormat() {
        val pcm = ByteArray(FRAME_BYTES * 20)
        repeat(20) { frame ->
            sineFrame(frame).copyInto(pcm, destinationOffset = frame * FRAME_BYTES)
        }

        assertEquals(640, FRAME_BYTES)
        assertEquals(12_800, pcm.size)
        assertTrue(pcmEnergy(pcm) > 50_000)
    }
}
