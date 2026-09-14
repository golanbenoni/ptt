package app.ptt.talk

import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import org.signal.libsignal.protocol.message.CiphertextMessage

class PersistentPairwiseCodecTest {
    @Test
    fun `regular message sentinel is not treated as a prekey message`() {
        assertTrue(PersistentPairwiseCrypto.shouldDecryptAsPreKey(1))
        assertTrue(PersistentPairwiseCrypto.shouldDecryptAsPreKey(Int.MAX_VALUE))
        assertEquals(false, PersistentPairwiseCrypto.shouldDecryptAsPreKey(-1))
        assertEquals(false, PersistentPairwiseCrypto.shouldDecryptAsPreKey(0))
    }

    @Test
    fun `pairwise outer envelope matches frozen Swift layout`() {
        val aci = "00112233-4455-4677-8899-aabbccddeeff"
        val encoded =
            PersistentPairwiseCrypto.encodeOuterEnvelope(
                aci,
                2,
                CiphertextMessage.WHISPER_TYPE,
                byteArrayOf(9, 8, 7),
            )
        assertArrayEquals(
            byteArrayOf(
                0x50, 0x54, 0x54, 0x45, 2,
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
                0x88.toByte(), 0x99.toByte(), 0xaa.toByte(), 0xbb.toByte(),
                0xcc.toByte(), 0xdd.toByte(), 0xee.toByte(), 0xff.toByte(),
                2, CiphertextMessage.WHISPER_TYPE.toByte(), 9, 8, 7,
            ),
            encoded,
        )
        val decoded = PersistentPairwiseCrypto.decodeOuterEnvelope(encoded)
        assertEquals(aci, decoded.senderAci)
        assertEquals(2, decoded.senderDeviceId)
        assertEquals(CiphertextMessage.WHISPER_TYPE, decoded.messageType)
        assertArrayEquals(byteArrayOf(9, 8, 7), decoded.ciphertext)
    }

    @Test
    fun `legacy outer envelope remains receive compatible`() {
        val decoded =
            PersistentPairwiseCrypto.decodeOuterEnvelope(
                byteArrayOf(
                    0x50, 0x54, 0x54, 0x45, 1,
                    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
                    0x88.toByte(), 0x99.toByte(), 0xaa.toByte(), 0xbb.toByte(),
                    0xcc.toByte(), 0xdd.toByte(), 0xee.toByte(), 0xff.toByte(),
                    2, 9, 8, 7,
                ),
            )
        assertEquals(null, decoded.messageType)
        assertArrayEquals(byteArrayOf(9, 8, 7), decoded.ciphertext)
    }

    @Test
    fun `prekey publication state is scoped to server account and device`() {
        val first =
            PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
                "https://ptt.example.test/",
                "00112233-4455-4677-8899-AABBCCDDEEFF",
                1,
            )
        assertEquals(
            first,
            PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
                "https://ptt.example.test",
                "00112233-4455-4677-8899-aabbccddeeff",
                1,
            ),
        )
        assertEquals(61, first.length)
        assertTrue(first.matches(Regex("[a-z0-9-]+")))
        assertNotEquals(
            first,
            PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
                "https://other.example.test",
                "00112233-4455-4677-8899-aabbccddeeff",
                1,
            ),
        )
        assertNotEquals(
            first,
            PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
                "https://ptt.example.test",
                "00112233-4455-4677-8899-aabbccddeeff",
                2,
            ),
        )
    }

    @Test
    fun `sender key envelope matches frozen Swift layout`() {
        val aci = "00112233-4455-4677-8899-aabbccddeeff"
        val distribution = UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f")
        val keyEnvelope = byteArrayOf(0x50, 0x54, 0x54, 0x45, 2, 2, 3)
        val ciphertext = byteArrayOf(9, 8, 7, 6)
        val encoded =
            PersistentPairwiseCrypto.encodeGroupEnvelope(
                aci,
                2,
                distribution,
                keyEnvelope,
                ciphertext,
            )

        assertArrayEquals(byteArrayOf(0x50, 0x54, 0x54, 0x47, 1), encoded.copyOfRange(0, 5))
        assertEquals(2, encoded[21].toInt())
        assertArrayEquals(
            byteArrayOf(
                0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x47, 0x87.toByte(),
                0x98.toByte(), 0xa9.toByte(), 0xba.toByte(), 0xcb.toByte(),
                0xdc.toByte(), 0xed.toByte(), 0xfe.toByte(), 0x0f,
            ),
            encoded.copyOfRange(22, 38),
        )
        assertArrayEquals(byteArrayOf(0, 0, 0, 7), encoded.copyOfRange(38, 42))
        val decoded = PersistentPairwiseCrypto.decodeGroupEnvelope(encoded)
        assertEquals(aci, decoded.senderAci)
        assertEquals(2, decoded.senderDeviceId)
        assertEquals(distribution, decoded.distributionId)
        assertArrayEquals(keyEnvelope, decoded.keyEnvelope)
        assertArrayEquals(ciphertext, decoded.ciphertext)
    }

    @Test
    fun `sender key distribution matches frozen Swift layout`() {
        val distribution = UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f")
        val encoded =
            PersistentPairwiseCrypto.encodeSenderKeyDistribution(
                distribution,
                byteArrayOf(1, 3, 5),
            )
        assertArrayEquals(byteArrayOf(0x50, 0x54, 0x54, 0x4b, 1), encoded.copyOfRange(0, 5))
        assertArrayEquals(byteArrayOf(0, 0, 0, 3), encoded.copyOfRange(21, 25))
        val decoded = PersistentPairwiseCrypto.decodeSenderKeyDistribution(encoded)
        assertEquals(distribution, decoded.distributionId)
        assertArrayEquals(byteArrayOf(1, 3, 5), decoded.message)
    }

    @Test
    fun `sender key codec rejects truncation and trailing length mismatch`() {
        assertThrows(IllegalArgumentException::class.java) {
            PersistentPairwiseCrypto.decodeGroupEnvelope(byteArrayOf(0x50, 0x54, 0x54, 0x47, 1))
        }
        val malformed =
            PersistentPairwiseCrypto.encodeSenderKeyDistribution(
                UUID.randomUUID(),
                byteArrayOf(1),
            ).copyOf().also { it[24] = 2 }
        assertThrows(IllegalArgumentException::class.java) {
            PersistentPairwiseCrypto.decodeSenderKeyDistribution(malformed)
        }
    }
}
