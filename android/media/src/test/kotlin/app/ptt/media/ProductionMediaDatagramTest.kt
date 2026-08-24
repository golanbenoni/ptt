package app.ptt.media

import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ProductionMediaDatagramTest {
    @Test
    fun `fixed voice envelope round trips through SFrame and authenticated UDP padding`() {
        val channel = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
        val talk = UUID.fromString("10213243-5465-7687-98a9-bacbdcedfe0f")
        val demux = 0xf123_4567L
        val key = ByteArray(32) { (it + 1).toByte() }
        val token = ByteArray(32) { (it + 65).toByte() }
        val opus = ByteArray(72) { (it * 3).toByte() }
        val aad = productionSFrameAad(channel, talk, demux)
        val encryptor = SFrameEncryptor(9u, key, MemorySFrameCounterStore())
        val sframe = encryptor.encrypt(aad, ProductionVoicePayload.pack(opus))
        val header =
            ProductionMediaHeader(
                MEDIA_FLAG_START or MEDIA_FLAG_HMAC8,
                demux,
                0xffff_fffeL,
                960,
                talkIdPrefix(talk),
            )
        val packet = ProductionMediaDatagram.encode(header, sframe, token)

        assertEquals(MEDIA_DATAGRAM_BYTES, packet.size)
        assertTrue(ProductionMediaDatagram.verifySenderAuthentication(packet, token))
        val received = ProductionMediaDatagram.decode(packet)
        assertEquals(demux, received.header.senderDemux)
        assertArrayEquals(talkIdPrefix(talk), received.header.talkIdPrefix)
        val decryptor = SFrameDecryptor().apply { addKey(9u, key) }
        assertArrayEquals(opus, ProductionVoicePayload.unpack(decryptor.decrypt(aad, received.sframe)))
    }

    @Test
    fun `tampering fails relay authentication and SFrame authentication`() {
        val key = ByteArray(32) { 7 }
        val token = ByteArray(32) { 8 }
        val channel = UUID.randomUUID()
        val talk = UUID.randomUUID()
        val aad = productionSFrameAad(channel, talk, 42)
        val sframe = SFrameEncryptor(1u, key, MemorySFrameCounterStore()).encrypt(
            aad,
            ProductionVoicePayload.pack(byteArrayOf(1, 2, 3)),
        )
        val packet = ProductionMediaDatagram.encode(
            ProductionMediaHeader(MEDIA_FLAG_HMAC8, 42, 1, 0, talkIdPrefix(talk)),
            sframe,
            token,
        )
        packet[40] = (packet[40].toInt() xor 1).toByte()
        assertFalse(ProductionMediaDatagram.verifySenderAuthentication(packet, token))
        val received = ProductionMediaDatagram.decode(packet)
        val decryptor = SFrameDecryptor().apply { addKey(1u, key) }
        assertThrows(SFrameException.AuthenticationFailed::class.java) {
            decryptor.decrypt(aad, received.sframe)
        }
    }

    @Test
    fun `voice envelope rejects oversized and noncanonical payloads`() {
        assertThrows(IllegalArgumentException::class.java) {
            ProductionVoicePayload.pack(ByteArray(MEDIA_MAX_OPUS_PACKET_BYTES + 1))
        }
        val noncanonical = ProductionVoicePayload.pack(byteArrayOf(1)).also { it[10] = 1 }
        assertThrows(IllegalArgumentException::class.java) { ProductionVoicePayload.unpack(noncanonical) }
    }
}
