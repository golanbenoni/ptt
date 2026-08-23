package app.ptt.media

import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class AesGcmFramesTest {
    @Test
    fun roundTrip() {
        val key = AesGcmFrames.newKey()
        val frames = AesGcmFrames(key)
        val talk = UUID.randomUUID()
        val aad = AesGcmFrames.aad(UUID(0, 0), talk, 7)
        val pcm = ByteArray(640) { it.toByte() }
        val pkt = frames.encrypt(1, aad, pcm)
        assertArrayEquals(pcm, frames.decrypt(aad, pkt))
    }

    @Test
    fun goldenVectorMatchesSwift() {
        val key = ByteArray(16) { it.toByte() }
        val channel = UUID.fromString("01020304-0506-4708-890a-0b0c0d0e0f10")
        val talk = UUID.fromString("11121314-1516-4718-991a-1b1c1d1e1f20")
        val aad = AesGcmFrames.aad(channel, talk, 0x01020304)
        val pkt = AesGcmFrames(key).encrypt(7, aad, "ptt-aes-gcm".toByteArray())
        assertEquals(
            "000000000000000739e75ddf0591cee0026974d93745ee74b750efef4655714edf3edc",
            pkt.joinToString("") { "%02x".format(it) },
        )
        assertArrayEquals("ptt-aes-gcm".toByteArray(), AesGcmFrames(key).decrypt(aad, pkt))
    }
}
