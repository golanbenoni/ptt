import Foundation
import Testing
@testable import PttTalkLib

@Test func encryptedMentionsMatchAndroidAndRemainLegacyReadable() throws {
    let local = "00112233-4455-4677-8899-aabbccddeeff"
    let teammate = "11112233-4455-4677-8899-aabbccddeeff"
    let mention = try #require(ChatMentions.mention(aci: local))
    #expect(mention.tag == "18a9ef1aae7e")
    #expect(mention.token == "@teammate-18a9ef1aae7e")
    let text = "Alert \(mention.token), check the relay."
    #expect(ChatMentions.rendered(text) == "Alert @Teammate 18A9, check the relay.")
    #expect(ChatMentions.containsLocalMention(text, localAci: local))
    #expect(!ChatMentions.containsLocalMention(text, localAci: teammate))
    #expect(!ChatMentions.containsLocalMention("\(mention.token)f", localAci: local))
    #expect(ChatMentions.rendered("\(mention.token)f") == "\(mention.token)f")
    let suggestions = ChatMentions.suggestions(acis: [local, teammate, teammate], localAci: local, draft: "Call @")
    #expect(suggestions.count == 1)
    #expect(ChatMentions.insert(try #require(suggestions.first), into: "Call @") == "Call \(suggestions[0].token) ")
    #expect(ChatMentions.suggestions(acis: [teammate], localAci: local, draft: "email@").isEmpty)

    func unread(_ body: String) -> ChatConversationMessage {
        ChatConversationMessage(message: ChatMessage(
            messageId: UUID(), channelId: UUID(), membershipEpoch: 1, sentAt: .distantPast,
            senderAci: teammate, senderDeviceId: 1, kind: .text, text: body
        ), isUnread: true)
    }
    let oldMention = unread(text)
    let newPlainText = unread("No alert for this muted follow-up")
    let newMention = unread(text)
    #expect(!ChatMentions.containsNewLocalMention(
        [oldMention, newPlainText], previouslyUnreadMessageIds: [oldMention.id], localAci: local
    ))
    #expect(ChatMentions.containsNewLocalMention(
        [oldMention, newMention], previouslyUnreadMessageIds: [oldMention.id], localAci: local
    ))
}

@Test func voiceWaveformMatchesFrozenAndroidV2Layout() throws {
    let message = ChatMessage(
        messageId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        channelId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7, sentAt: Date(timeIntervalSince1970: 1),
        senderAci: "12345678-1234-4234-9234-123456789abc", senderDeviceId: 2,
        kind: .voice, text: "",
        attachment: ChatAttachment(
            attachmentId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!,
            fileName: "voice.m4a", mimeType: "audio/mp4", plaintextBytes: 18,
            durationMs: 1_200, waveform: Data([8, 64, 127, 255]),
            key: Data(0..<32), ciphertextSha256: Data(32..<64)
        )
    )
    #expect(try EncryptedChatCodec.encode(message).map { String(format: "%02x", $0) }.joined() ==
        "50545443020300112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b0090904000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff766f6963652e6d3461617564696f2f6d7034")
    let legacyMessage = ChatMessage(
        messageId: message.messageId, channelId: message.channelId,
        membershipEpoch: message.membershipEpoch, sentAt: message.sentAt,
        senderAci: message.senderAci, senderDeviceId: 2, kind: .voice, text: "",
        attachment: ChatAttachment(
            attachmentId: message.attachment!.attachmentId, fileName: "voice.m4a",
            mimeType: "audio/mp4", plaintextBytes: 18, durationMs: 1_200,
            key: Data(0..<32), ciphertextSha256: Data(32..<64)
        )
    )
    var v1 = try EncryptedChatCodec.encode(legacyMessage)
    v1.remove(at: 84)
    v1[4] = 1
    #expect(try EncryptedChatCodec.decode(v1, senderAci: message.senderAci, senderDeviceId: 2)
        .attachment?.waveform.isEmpty == true)
}

@Test func encryptedThumbnailMatchesFrozenAndroidV3Layout() throws {
    let thumbnail = ChatThumbnail(
        thumbnailId: UUID(uuidString: "20314253-6475-4897-a8b9-cadbecfd0e1f")!,
        mimeType: "image/jpeg", plaintextBytes: 12, width: 320, height: 180,
        key: Data(64..<96), ciphertextSha256: Data(96..<128)
    )
    let message = ChatMessage(
        messageId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        channelId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7, sentAt: Date(timeIntervalSince1970: 1),
        senderAci: "12345678-1234-4234-9234-123456789abc", senderDeviceId: 2,
        kind: .video, text: "",
        attachment: ChatAttachment(
            attachmentId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!,
            fileName: "clip.mp4", mimeType: "video/mp4", plaintextBytes: 18,
            durationMs: 1_200, waveform: Data([8, 64, 127, 255]), thumbnail: thumbnail,
            key: Data(0..<32), ciphertextSha256: Data(32..<64)
        )
    )
    let frozen = "50545443030400112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b00809040a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff2031425364754897a8b9cadbecfd0e1f0000000c014000b4404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f696d6167652f6a706567636c69702e6d7034766964656f2f6d7034"
    let encoded = try EncryptedChatCodec.encode(message)
    #expect(encoded.map { String(format: "%02x", $0) }.joined() == frozen)
    #expect(try EncryptedChatCodec.decode(
        encoded, senderAci: message.senderAci, senderDeviceId: message.senderDeviceId
    ) == message)
}

@Test func encryptedThumbnailRoundTripAndTamperRejection() throws {
    let thumbnailId = UUID()
    let channelId = UUID()
    let plaintext = Data("private preview".utf8)
    let sealed = try EncryptedChatCodec.sealThumbnail(
        plaintext, thumbnailId: thumbnailId, channelId: channelId,
        membershipEpoch: 9, key: Data(0..<32)
    )
    let metadata = ChatThumbnail(
        thumbnailId: thumbnailId, mimeType: "image/jpeg",
        plaintextBytes: Int32(plaintext.count), width: 320, height: 180,
        key: sealed.key, ciphertextSha256: sealed.sha256
    )
    #expect(try EncryptedChatCodec.openThumbnail(
        sealed.ciphertext, metadata: metadata, channelId: channelId, membershipEpoch: 9
    ) == plaintext)
    let attachment = Data("PTTA\u{1}main".utf8)
    let bundle = try EncryptedChatCodec.packAttachmentCiphertexts(
        attachment: attachment, thumbnail: sealed.ciphertext
    )
    let unpacked = try EncryptedChatCodec.unpackAttachmentCiphertexts(bundle)
    #expect(unpacked.attachment == attachment)
    #expect(unpacked.thumbnail == sealed.ciphertext)
    #expect(try EncryptedChatCodec.unpackAttachmentCiphertexts(attachment).attachment == attachment)
    var altered = sealed.ciphertext
    altered[altered.count - 1] ^= 1
    #expect(throws: EncryptedChatError.attachmentIntegrityFailed) {
        try EncryptedChatCodec.openThumbnail(
            altered, metadata: metadata, channelId: channelId, membershipEpoch: 9
        )
    }
}

@Test func attachmentArchiveDecodesRecordsWrittenBeforeWaveforms() throws {
    let legacy = """
    {"attachmentId":"10213243-5465-4787-98A9-BACBDCEDFE0F","fileName":"voice.m4a","mimeType":"audio/mp4","plaintextBytes":18,"durationMs":1200,"key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","ciphertextSha256":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="}
    """
    let decoded = try JSONDecoder().decode(ChatAttachment.self, from: Data(legacy.utf8))
    #expect(decoded.waveform.isEmpty)
    #expect(decoded.thumbnail == nil)
    #expect(decoded.durationMs == 1_200)
}

@Test func chatTextMatchesFrozenAndroidLayout() throws {
    let message = ChatMessage(
        messageId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        channelId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7,
        sentAt: Date(timeIntervalSince1970: 1),
        senderAci: "12345678-1234-4234-9234-123456789abc",
        senderDeviceId: 2,
        kind: .text,
        text: "hi"
    )
    let encoded = try EncryptedChatCodec.encode(message)
    #expect(encoded.map { String(format: "%02x", $0) }.joined() ==
        "50545443010100112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8000000026869")
    #expect(try EncryptedChatCodec.decode(
        encoded,
        senderAci: message.senderAci,
        senderDeviceId: message.senderDeviceId
    ) == message)
}

@Test func encryptedChatAttachmentRoundTripAndTamperRejection() throws {
    let attachmentId = UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    let channelId = UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!
    let plaintext = Data("private voice note".utf8)
    let sealed = try EncryptedChatCodec.sealAttachment(
        plaintext,
        attachmentId: attachmentId,
        channelId: channelId,
        membershipEpoch: 7,
        key: Data(0..<32)
    )
    let metadata = ChatAttachment(
        attachmentId: attachmentId,
        fileName: "voice.m4a",
        mimeType: "audio/mp4",
        plaintextBytes: Int64(plaintext.count),
        durationMs: 1_200,
        waveform: Data([8, 64, 127, 255]),
        key: sealed.key,
        ciphertextSha256: sealed.sha256
    )
    #expect(try EncryptedChatCodec.openAttachment(
        sealed.ciphertext,
        metadata: metadata,
        channelId: channelId,
        membershipEpoch: 7
    ) == plaintext)
    let voiceMessage = ChatMessage(
        messageId: UUID(), channelId: channelId, membershipEpoch: 7,
        sentAt: Date(timeIntervalSince1970: 1), senderAci: UUID().uuidString.lowercased(),
        senderDeviceId: 1, kind: .voice, text: "", attachment: metadata
    )
    #expect(try EncryptedChatCodec.decode(
        EncryptedChatCodec.encode(voiceMessage), senderAci: voiceMessage.senderAci, senderDeviceId: 1
    ).attachment?.waveform == metadata.waveform)
    var altered = sealed.ciphertext
    altered[altered.count - 1] ^= 1
    #expect(throws: EncryptedChatError.attachmentIntegrityFailed) {
        try EncryptedChatCodec.openAttachment(altered, metadata: metadata, channelId: channelId, membershipEpoch: 7)
    }
}

@Test func chatRejectsOversizeAndKindConfusion() {
    let base = ChatMessage(
        messageId: UUID(), channelId: UUID(), membershipEpoch: 1, sentAt: Date(),
        senderAci: UUID().uuidString, senderDeviceId: 1, kind: .text,
        text: String(repeating: "x", count: EncryptedChatCodec.maximumTextBytes + 1)
    )
    #expect(throws: EncryptedChatError.textTooLarge) { try EncryptedChatCodec.encode(base) }
}

@Test func chatReceiptEventMatchesFrozenAndroidLayout() throws {
    let event = ChatEvent(
        eventId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        channelId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7,
        sentAt: Date(timeIntervalSince1970: 1),
        senderAci: "12345678-1234-4234-9234-123456789abc",
        senderDeviceId: 2,
        kind: .delivered,
        targetMessageId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    )
    let encoded = try EncryptedChatCodec.encodeEvent(event)
    #expect(encoded.map { String(format: "%02x", $0) }.joined() ==
        "50545445010200112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8102132435465478798a9bacbdcedfe0f0000000000000000000000000000000000000000")
    #expect(try EncryptedChatCodec.decodeEvent(
        encoded, senderAci: event.senderAci, senderDeviceId: event.senderDeviceId
    ) == event)
}

@Test func chatMessageEventCarriesReplyAndAcceptsLegacyMessage() throws {
    let message = ChatMessage(
        messageId: UUID(), channelId: UUID(), membershipEpoch: 3,
        sentAt: Date(timeIntervalSince1970: 2), senderAci: UUID().uuidString.lowercased(),
        senderDeviceId: 1, kind: .text, text: "reply"
    )
    let event = ChatEvent.message(message, replyTo: UUID())
    let encoded = try EncryptedChatCodec.encodeEvent(event)
    #expect(try EncryptedChatCodec.decodeEvent(
        encoded, senderAci: message.senderAci, senderDeviceId: 1
    ) == event)
    #expect(try EncryptedChatCodec.decodeEventOrLegacyMessage(
        EncryptedChatCodec.encode(message), senderAci: message.senderAci, senderDeviceId: 1
    ) == ChatEvent.message(message))
}

@Test func chatPinEventMatchesFrozenAndroidLayout() throws {
    let event = ChatEvent(
        eventId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        channelId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7, sentAt: Date(timeIntervalSince1970: 1),
        senderAci: "12345678-1234-4234-9234-123456789abc", senderDeviceId: 2,
        kind: .pin, targetMessageId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    )
    let encoded = try EncryptedChatCodec.encodeEvent(event)
    #expect(encoded.map { String(format: "%02x", $0) }.joined() ==
        "50545445010900112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8102132435465478798a9bacbdcedfe0f0000000000000000000000000000000000000000")
    #expect(try EncryptedChatCodec.decodeEvent(
        encoded, senderAci: event.senderAci, senderDeviceId: event.senderDeviceId
    ) == event)
}

@Test func chatEventRejectsInvalidMutationShapes() {
    let event = ChatEvent(
        eventId: UUID(), channelId: UUID(), membershipEpoch: 1, sentAt: Date(),
        senderAci: UUID().uuidString, senderDeviceId: 1, kind: .read
    )
    #expect(throws: EncryptedChatError.invalidEvent) { try EncryptedChatCodec.encodeEvent(event) }
}

@Test func chatEventReducerAppliesOnlyAuthorizedCausalMutations() {
    let channel = UUID()
    let alice = UUID().uuidString.lowercased()
    let bob = UUID().uuidString.lowercased()
    let message = ChatMessage(
        messageId: UUID(), channelId: channel, membershipEpoch: 1,
        sentAt: Date(timeIntervalSince1970: 10), senderAci: alice,
        senderDeviceId: 1, kind: .text, text: "before"
    )
    func event(_ kind: ChatEventKind, sender: String, target: UUID, value: String = "", offset: TimeInterval) -> ChatEvent {
        ChatEvent(
            eventId: UUID(), channelId: channel, membershipEpoch: 1,
            sentAt: message.sentAt.addingTimeInterval(offset), senderAci: sender,
            senderDeviceId: 1, kind: kind, targetMessageId: target, value: value
        )
    }
    var events = [
        ChatEvent.message(message),
        event(.edit, sender: bob, target: message.messageId, value: "forged", offset: 1),
        event(.edit, sender: alice, target: message.messageId, value: "after", offset: 2),
        event(.reaction, sender: bob, target: message.messageId, value: "👍", offset: 3),
        event(.read, sender: bob, target: message.messageId, offset: 4),
        event(.pin, sender: bob, target: message.messageId, offset: 4.5),
    ]
    var reduced = ChatEventReducer.reduce(events, channelId: channel, localAci: bob)
    #expect(reduced.count == 1)
    #expect(reduced[0].displayText == "after")
    #expect(reduced[0].reactions[bob] == "👍")
    #expect(reduced[0].receipts["\(bob):1"] == .read)
    #expect(!reduced[0].isUnread)
    #expect(reduced[0].isPinned)

    events.append(event(.unpin, sender: alice, target: message.messageId, offset: 4.75))
    reduced = ChatEventReducer.reduce(events, channelId: channel, localAci: bob)
    #expect(!reduced[0].isPinned)
    events.append(event(.pin, sender: alice, target: message.messageId, offset: 4.9))

    events.append(event(.delete, sender: alice, target: message.messageId, offset: 5))
    reduced = ChatEventReducer.reduce(events, channelId: channel, localAci: bob)
    #expect(reduced[0].isDeleted)
    #expect(reduced[0].displayText.isEmpty)
    #expect(reduced[0].reactions.isEmpty)
    #expect(!reduced[0].isPinned)
}

@Test func secureChatArchivePersistsPrunesAndErasesCiphertext() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = UUID()
    func message(_ offset: TimeInterval) -> ChatMessage {
        ChatMessage(
            messageId: UUID(), channelId: channel, membershipEpoch: 1,
            sentAt: Date().addingTimeInterval(offset), senderAci: UUID().uuidString,
            senderDeviceId: 1, kind: .text, text: String(repeating: "private", count: 40)
        )
    }
    let first = message(-2)
    let second = message(-1)
    // Reuse an identical expiry value so JSON's floating-point date spelling
    // cannot change the encrypted record length between measurement and prune.
    let expiresAt = Date().addingTimeInterval(60)
    let measuring = try SecureChatArchive(
        namespace: "test-chat-measure-\(UUID().uuidString)", directory: root,
        testKey: Data(repeating: 0x27, count: 32), maximumBytes: 100_000
    )
    try measuring.put(first, expiresAt: expiresAt)
    try measuring.put(second, expiresAt: expiresAt)
    let measuredRecords = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.fileSizeKey]
    ).filter { $0.lastPathComponent.hasPrefix("message-") }.map {
        Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    let singleRecordLimit = try #require(measuredRecords.max())
    try measuring.erase()
    let pruning = try SecureChatArchive(
        namespace: "test-chat-prune-\(UUID().uuidString)", directory: root,
        testKey: Data(repeating: 0x27, count: 32), maximumBytes: singleRecordLimit
    )
    try pruning.put(first, expiresAt: expiresAt)
    try pruning.put(second, expiresAt: expiresAt)
    let retained = try pruning.messages(channelId: channel)
    #expect(retained.last?.messageId == second.messageId)
    #expect(retained.count < 2)

    try pruning.erase()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func secureChatArchiveBoundsAndCancelsPartialCiphertext() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 0x51, count: 32)
    let messageId = UUID()
    let objectId = UUID()
    let bounded = try SecureChatArchive(
        namespace: "test-chat-partial-bound-\(UUID().uuidString)", directory: root,
        testKey: key, maximumBytes: 16
    )
    try bounded.cachePartialAttachment(Data(repeating: 0x22, count: 32), messageId: messageId, objectId: objectId)
    #expect(try bounded.partialAttachment(messageId: messageId, objectId: objectId) == nil)
    try bounded.erase()

    let archive = try SecureChatArchive(
        namespace: "test-chat-partial-cancel-\(UUID().uuidString)", directory: root,
        testKey: key, maximumBytes: 100_000
    )
    let message = ChatMessage(
        messageId: messageId, channelId: UUID(), membershipEpoch: 1,
        sentAt: Date(), senderAci: UUID().uuidString.lowercased(),
        senderDeviceId: 1, kind: .text, text: "cancel"
    )
    let event = ChatEvent.message(message)
    try archive.putEvent(event, expiresAt: Date().addingTimeInterval(60))
    try archive.putOutbox(event: event, recipients: [], expiresAt: Date().addingTimeInterval(60))
    try archive.cachePartialAttachment(Data(repeating: 0x33, count: 32), messageId: messageId, objectId: objectId)
    #expect(try archive.partialAttachment(messageId: messageId, objectId: objectId)?.count == 32)
    try archive.cancelSend(event.eventId)
    #expect(try archive.partialAttachment(messageId: messageId, objectId: objectId) == nil)
}

@Test func secureChatArchivePersistsConversationEventsAndUnreadState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 0x39, count: 32)
    let channel = UUID()
    let alice = UUID().uuidString.lowercased()
    let bob = UUID().uuidString.lowercased()
    let message = ChatMessage(
        messageId: UUID(), channelId: channel, membershipEpoch: 2,
        sentAt: Date().addingTimeInterval(-5), senderAci: alice,
        senderDeviceId: 1, kind: .text, text: "before"
    )
    let expiry = Date().addingTimeInterval(60)
    let events = [
        ChatEvent.message(message),
        ChatEvent(
            eventId: UUID(), channelId: channel, membershipEpoch: 2,
            sentAt: message.sentAt.addingTimeInterval(1), senderAci: alice,
            senderDeviceId: 1, kind: .edit, targetMessageId: message.messageId, value: "after"
        ),
        ChatEvent(
            eventId: UUID(), channelId: channel, membershipEpoch: 2,
            sentAt: message.sentAt.addingTimeInterval(2), senderAci: bob,
            senderDeviceId: 2, kind: .reaction, targetMessageId: message.messageId, value: "👍"
        ),
    ]
    var archive = try SecureChatArchive(
        namespace: "test-chat-events-\(UUID().uuidString)", directory: root,
        testKey: key, maximumBytes: 100_000
    )
    for event in events { try archive.putEvent(event, expiresAt: expiry) }
    let recipient = ChatRecipient(aci: bob, deviceId: 2, envelope: Data([1, 2, 3]))
    try archive.putOutbox(event: events[0], recipients: [], expiresAt: expiry)
    #expect(try archive.outbox().first?.state == .queued)
    try archive.resolveOutboxRecipients(events[0].eventId, recipients: [recipient])
    #expect(try archive.outbox().first?.recipients == [recipient])
    #expect(throws: EncryptedChatError.invalidEvent) {
        try archive.resolveOutboxRecipients(
            events[0].eventId,
            recipients: [ChatRecipient(aci: bob, deviceId: 2, envelope: Data([9, 9, 9]))]
        )
    }
    try archive.markOutbox(events[0].eventId, state: .sending)
    #expect(try archive.outbox().first?.attemptCount == 1)
    #expect(try archive.unreadCount(channelId: channel, localAci: bob) == 1)

    archive = try SecureChatArchive(
        namespace: "test-chat-events-reopen-\(UUID().uuidString)", directory: root,
        testKey: key, maximumBytes: 100_000
    )
    var reduced = try archive.conversation(channelId: channel, localAci: bob)
    #expect(reduced.count == 1)
    #expect(reduced[0].displayText == "after")
    #expect(reduced[0].reactions[bob] == "👍")
    #expect(try archive.outbox().first?.recipients == [recipient])
    try archive.removeOutbox(events[0].eventId)
    #expect(try archive.outbox().isEmpty)
    let read = ChatEvent(
        eventId: UUID(), channelId: channel, membershipEpoch: 2,
        sentAt: message.sentAt.addingTimeInterval(3), senderAci: bob,
        senderDeviceId: 2, kind: .read, targetMessageId: message.messageId
    )
    try archive.putEvent(read, expiresAt: expiry)
    reduced = try archive.conversation(channelId: channel, localAci: bob)
    #expect(!reduced[0].isUnread)
    #expect(reduced[0].receipts["\(bob):2"] == .read)
}
