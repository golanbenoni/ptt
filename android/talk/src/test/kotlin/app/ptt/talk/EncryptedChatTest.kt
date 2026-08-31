package app.ptt.talk

import java.time.Instant
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class EncryptedChatTest {
    @Test fun productProtocolContractFailsClosed() {
        fun validate(
            protocolMinor: Int = 1,
            minimumClientMinor: Int = 0,
            capabilities: Set<String> = ProductProtocolContract.requiredCapabilities,
        ) = ProductProtocolContract.validate(1, protocolMinor, 1, minimumClientMinor, capabilities)
        assertEquals(1, validate().protocolMinor)
        assertEquals(
            "SERVER_UPGRADE_REQUIRED",
            assertThrows(ControlApiException::class.java) { validate(protocolMinor = 0) }.code,
        )
        assertEquals(
            "CLIENT_UPGRADE_REQUIRED",
            assertThrows(ControlApiException::class.java) { validate(minimumClientMinor = 2) }.code,
        )
        assertEquals(
            "SERVER_CAPABILITY_REQUIRED",
            assertThrows(ControlApiException::class.java) { validate(capabilities = emptySet()) }.code,
        )
    }

    @Test fun voiceWaveformMatchesFrozenSwiftV2Layout() {
        val message = ChatMessage(
            UUID.fromString("00112233-4455-4677-8899-aabbccddeeff"),
            UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100"), 7,
            Instant.ofEpochMilli(1_000), "12345678-1234-4234-9234-123456789abc", 2,
            ChatContentKind.VOICE, "",
            ChatAttachment(
                UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f"),
                "voice.m4a", "audio/mp4", 18, 1_200, byteArrayOf(8, 64, 127, -1),
                ByteArray(32) { it.toByte() }, ByteArray(32) { (it + 32).toByte() },
            ),
        )
        assertEquals(
            "50545443020300112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b0090904000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff766f6963652e6d3461617564696f2f6d7034",
            EncryptedChatCodec.encode(message).joinToString("") { "%02x".format(it) },
        )
        val withoutWaveform = message.copy(attachment = message.attachment!!.copy(waveform = byteArrayOf()))
        val v2 = EncryptedChatCodec.encode(withoutWaveform)
        val v1 = (v2.copyOfRange(0, 84) + v2.copyOfRange(85, v2.size)).also { it[4] = 1 }
        assertEquals(0, EncryptedChatCodec.decode(v1, message.senderAci, 2).attachment?.waveform?.size)
    }

    @Test fun encryptedThumbnailMatchesFrozenSwiftV3Layout() {
        val thumbnail = ChatThumbnail(
            UUID.fromString("20314253-6475-4897-a8b9-cadbecfd0e1f"),
            "image/jpeg", 12, 320, 180,
            ByteArray(32) { (it + 64).toByte() }, ByteArray(32) { (it + 96).toByte() },
        )
        val message = ChatMessage(
            UUID.fromString("00112233-4455-4677-8899-aabbccddeeff"),
            UUID.fromString("ffeeddcc-bbaa-4988-8766-554433221100"), 7,
            Instant.ofEpochMilli(1_000), "12345678-1234-4234-9234-123456789abc", 2,
            ChatContentKind.VIDEO, "",
            ChatAttachment(
                UUID.fromString("10213243-5465-4787-98a9-bacbdcedfe0f"),
                "clip.mp4", "video/mp4", 18, 1_200, byteArrayOf(8, 64, 127, -1),
                ByteArray(32) { it.toByte() }, ByteArray(32) { (it + 32).toByte() }, thumbnail,
            ),
        )
        val frozen = "50545443030400112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b00809040a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff2031425364754897a8b9cadbecfd0e1f0000000c014000b4404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f696d6167652f6a706567636c69702e6d7034766964656f2f6d7034"
        val encoded = EncryptedChatCodec.encode(message)
        assertEquals(frozen, encoded.joinToString("") { "%02x".format(it) })
        val decoded = EncryptedChatCodec.decode(encoded, message.senderAci, 2)
        assertEquals(message.attachment?.thumbnail?.thumbnailId, decoded.attachment?.thumbnail?.thumbnailId)
        assertEquals(message.attachment?.thumbnail?.mimeType, decoded.attachment?.thumbnail?.mimeType)
        assertArrayEquals(message.attachment?.thumbnail?.key, decoded.attachment?.thumbnail?.key)
        assertArrayEquals(message.attachment?.thumbnail?.ciphertextSha256, decoded.attachment?.thumbnail?.ciphertextSha256)
    }

    @Test fun encryptedThumbnailRoundTripAndTamperRejection() {
        val thumbnailId = UUID.randomUUID()
        val channelId = UUID.randomUUID()
        val plaintext = "private preview".encodeToByteArray()
        val sealed = EncryptedChatCodec.sealThumbnail(
            plaintext, thumbnailId, channelId, 9, ByteArray(32) { it.toByte() },
        )
        val metadata = ChatThumbnail(
            thumbnailId, "image/jpeg", plaintext.size, 320, 180, sealed.second, sealed.third,
        )
        assertArrayEquals(plaintext, EncryptedChatCodec.openThumbnail(sealed.first, metadata, channelId, 9))
        val attachment = "PTTA\u0001main".encodeToByteArray()
        val bundle = EncryptedChatCodec.packAttachmentCiphertexts(attachment, sealed.first)
        val unpacked = EncryptedChatCodec.unpackAttachmentCiphertexts(bundle)
        assertArrayEquals(attachment, unpacked.first)
        assertArrayEquals(sealed.first, unpacked.second)
        assertArrayEquals(attachment, EncryptedChatCodec.unpackAttachmentCiphertexts(attachment).first)
        val altered = sealed.first.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        assertThrows(Exception::class.java) {
            EncryptedChatCodec.openThumbnail(altered, metadata, channelId, 9)
        }
    }

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
            attachmentId, "voice.m4a", "audio/mp4", plaintext.size.toLong(), 1_200,
            byteArrayOf(8, 64, 127, -1), sealed.second, sealed.third,
        )
        val message = ChatMessage(
            UUID.randomUUID(), channelId, 7, Instant.ofEpochMilli(1_000),
            UUID.randomUUID().toString().lowercase(), 1, ChatContentKind.VOICE, "", metadata,
        )
        val decoded = EncryptedChatCodec.decode(
            EncryptedChatCodec.encode(message), message.senderAci, message.senderDeviceId,
        )
        assertArrayEquals(metadata.waveform, decoded.attachment?.waveform)
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
