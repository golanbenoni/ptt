package app.ptt.talk

import java.time.Instant
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class EncryptedChatTest {
    @Test fun textMatchesFrozenSwiftLayout() {
        val message = ChatMessage(
            UUID.fromString("00112233-4455-4677-8899-aabbccddeeff"),
            UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100"),
            7,
            Instant.ofEpochMilli(1_000),
            "12345678-1234-4234-9234-123456789abc",
            2,
            ChatContentKind.TEXT,
            "hi",
        )
        val encoded = EncryptedChatCodec.encode(message)
        assertEquals(
            "50545443010100112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8000000026869",
            encoded.joinToString("") { "%02x".format(it) },
        )
        assertEquals(message, EncryptedChatCodec.decode(encoded, message.senderAci, message.senderDeviceId))
    }

    @Test fun attachmentRoundTripAndTamperRejection() {
        val attachmentId = UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f")
        val channelId = UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100")
        val plaintext = "private voice note".encodeToByteArray()
        val sealed = EncryptedChatCodec.sealAttachment(plaintext, attachmentId, channelId, 7, ByteArray(32) { it.toByte() })
        val metadata = ChatAttachment(
            attachmentId, "voice.m4a", "audio/mp4", plaintext.size.toLong(), 1_200, sealed.second, sealed.third,
        )
        assertArrayEquals(plaintext, EncryptedChatCodec.openAttachment(sealed.first, metadata, channelId, 7))
        val altered = sealed.first.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        assertThrows(Exception::class.java) { EncryptedChatCodec.openAttachment(altered, metadata, channelId, 7) }
    }
}
