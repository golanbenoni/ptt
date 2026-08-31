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

    @Test fun receiptEventMatchesFrozenSwiftLayout() {
        val event = ChatEvent(
            UUID.fromString("00112233-4455-4677-8899-aabbccddeeff"),
            UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100"),
            7,
            Instant.ofEpochMilli(1_000),
            "12345678-1234-4234-9234-123456789abc",
            2,
            ChatEventKind.DELIVERED,
            targetMessageId = UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f"),
        )
        val encoded = EncryptedChatCodec.encodeEvent(event)
        assertEquals(
            "50545445010200112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8102132435465478798a9bacbdcedfe0f0000000000000000000000000000000000000000",
            encoded.joinToString("") { "%02x".format(it) },
        )
        assertEquals(event, EncryptedChatCodec.decodeEvent(encoded, event.senderAci, event.senderDeviceId))
    }

    @Test fun messageEventCarriesReplyAndAcceptsLegacyMessage() {
        val message = ChatMessage(
            UUID.randomUUID(), UUID.randomUUID(), 3, Instant.ofEpochMilli(2_000),
            UUID.randomUUID().toString().lowercase(), 1, ChatContentKind.TEXT, "reply",
        )
        val event = ChatEvent.message(message, UUID.randomUUID())
        assertEquals(
            event,
            EncryptedChatCodec.decodeEvent(
                EncryptedChatCodec.encodeEvent(event), message.senderAci, message.senderDeviceId,
            ),
        )
        assertEquals(
            ChatEvent.message(message),
            EncryptedChatCodec.decodeEventOrLegacyMessage(
                EncryptedChatCodec.encode(message), message.senderAci, message.senderDeviceId,
            ),
        )
    }

    @Test fun pinEventMatchesFrozenSwiftLayout() {
        val event = ChatEvent(
            UUID.fromString("00112233-4455-4677-8899-aabbccddeeff"),
            UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100"), 7,
            Instant.ofEpochMilli(1_000), "12345678-1234-4234-9234-123456789abc", 2,
            ChatEventKind.PIN, targetMessageId = UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f"),
        )
        val encoded = EncryptedChatCodec.encodeEvent(event)
        assertEquals(
            "50545445010900112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8102132435465478798a9bacbdcedfe0f0000000000000000000000000000000000000000",
            encoded.joinToString("") { "%02x".format(it) },
        )
        assertEquals(event, EncryptedChatCodec.decodeEvent(encoded, event.senderAci, event.senderDeviceId))
    }

    @Test fun invalidMutationShapeIsRejected() {
        val event = ChatEvent(
            UUID.randomUUID(), UUID.randomUUID(), 1, Instant.now(),
            UUID.randomUUID().toString(), 1, ChatEventKind.READ,
        )
        assertThrows(IllegalArgumentException::class.java) { EncryptedChatCodec.encodeEvent(event) }
    }

    @Test fun reducerAppliesOnlyAuthorizedCausalMutations() {
        val channel = UUID.randomUUID()
        val alice = UUID.randomUUID().toString().lowercase()
        val bob = UUID.randomUUID().toString().lowercase()
        val message = ChatMessage(
            UUID.randomUUID(), channel, 1, Instant.ofEpochSecond(10), alice, 1,
            ChatContentKind.TEXT, "before",
        )
        fun event(kind: ChatEventKind, sender: String, value: String = "", offset: Long) = ChatEvent(
            UUID.randomUUID(), channel, 1, message.sentAt.plusSeconds(offset), sender, 1,
            kind, targetMessageId = message.messageId, value = value,
        )
        val events = mutableListOf(
            ChatEvent.message(message),
            event(ChatEventKind.EDIT, bob, "forged", 1),
            event(ChatEventKind.EDIT, alice, "after", 2),
            event(ChatEventKind.REACTION, bob, "👍", 3),
            event(ChatEventKind.READ, bob, offset = 4),
            event(ChatEventKind.PIN, bob, offset = 5),
        )
        var reduced = ChatEventReducer.reduce(events, channel, bob)
        assertEquals(1, reduced.size)
        assertEquals("after", reduced.single().displayText)
        assertEquals("👍", reduced.single().reactions[bob])
        assertEquals(ChatReceiptState.READ, reduced.single().receipts["$bob:1"])
        assertEquals(false, reduced.single().isUnread)
        assertEquals(true, reduced.single().isPinned)

        events += event(ChatEventKind.UNPIN, alice, offset = 6)
        reduced = ChatEventReducer.reduce(events, channel, bob)
        assertEquals(false, reduced.single().isPinned)
        events += event(ChatEventKind.PIN, alice, offset = 7)
        events += event(ChatEventKind.DELETE, alice, offset = 8)
        reduced = ChatEventReducer.reduce(events, channel, bob)
        assertEquals(true, reduced.single().isDeleted)
        assertEquals("", reduced.single().displayText)
        assertEquals(emptyMap<String, String>(), reduced.single().reactions)
        assertEquals(false, reduced.single().isPinned)
    }
}
