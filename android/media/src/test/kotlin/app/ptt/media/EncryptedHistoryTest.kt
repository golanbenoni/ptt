package app.ptt.media

import java.util.UUID
import java.security.MessageDigest
import javax.crypto.AEADBadTagException
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class EncryptedHistoryTest {
    private val channel = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
    private val talk = UUID.fromString("10213243-5465-7687-98a9-bacbdcedfe0f")
    private val key = ByteArray(32) { it.toByte() }
    private val packets = listOf(ByteArray(160) { it.toByte() }, ByteArray(160) { (255 - it).toByte() })

    @Test
    fun `history round trips and has frozen cross-platform prefix`() {
        val blob = EncryptedHistory.seal(channel, talk, 7, 0x0102_0304_0506_0708u, key, packets, ByteArray(12) { it.toByte() })
        assertEquals("5054544801000102030405060708090a0b", blob.take(17).toByteArray().toHex())
        assertEquals(
            "f400a59caf393f5a249f83d6c384eac992948e4f036a716fcce6f194f55e5679",
            MessageDigest.getInstance("SHA-256").digest(blob).toHex(),
        )
        val opened = EncryptedHistory.open(blob, channel, talk, 7, 0x0102_0304_0506_0708u, key)
        assertEquals(2, opened.size)
        assertArrayEquals(packets[0], opened[0])
        assertArrayEquals(packets[1], opened[1])
    }

    @Test
    fun `history rejects ciphertext and metadata tampering`() {
        val blob = EncryptedHistory.seal(channel, talk, 7, 9u, key, packets, ByteArray(12))
        blob[blob.lastIndex] = (blob.last().toInt() xor 1).toByte()
        assertThrows(AEADBadTagException::class.java) { EncryptedHistory.open(blob, channel, talk, 7, 9u, key) }
        val valid = EncryptedHistory.seal(channel, talk, 7, 9u, key, packets, ByteArray(12))
        assertThrows(AEADBadTagException::class.java) { EncryptedHistory.open(valid, channel, talk, 8, 9u, key) }
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
