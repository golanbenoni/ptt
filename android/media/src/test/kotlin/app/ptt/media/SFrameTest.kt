package app.ptt.media

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class SFrameTest {
    @Test
    fun rfc9605Aes128GcmVectorMatchesRust() {
        val key = hex("000102030405060708090a0b0c0d0e0f")
        val metadata = hex("4945544620534672616d65205747")
        val plaintext = hex("64726166742d696574662d736672616d652d656e63")
        val encryptor = SFrameEncryptor(0x0123u, key, MemorySFrameCounterStore())
        val frame = encryptor.encryptWithCounter(0x4567u, metadata, plaintext)
        assertEquals(
            "9901234567b7412c2513a1b66dbb48841bbaf17f598751176ad847681a69c6d0b091c07018ce4adb34eb",
            frame.hex(),
        )
        val decryptor = SFrameDecryptor()
        decryptor.addKey(0x0123u, key)
        assertArrayEquals(plaintext, decryptor.decrypt(metadata, frame))
    }

    @Test
    fun replayAndAuthenticationFailuresFailClosed() {
        val key = ByteArray(16) { 9 }
        val encryptor = SFrameEncryptor(1u, key, MemorySFrameCounterStore())
        val frame = encryptor.encrypt("aad".encodeToByteArray(), "voice".encodeToByteArray())
        val decryptor = SFrameDecryptor()
        decryptor.addKey(1u, key)
        val corrupt = frame.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertThrows(SFrameException.AuthenticationFailed::class.java) {
            decryptor.decrypt("aad".encodeToByteArray(), corrupt)
        }
        assertArrayEquals("voice".encodeToByteArray(), decryptor.decrypt("aad".encodeToByteArray(), frame))
        assertThrows(SFrameException.Replay::class.java) {
            decryptor.decrypt("aad".encodeToByteArray(), frame)
        }
    }

    private fun hex(value: String): ByteArray =
        value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
