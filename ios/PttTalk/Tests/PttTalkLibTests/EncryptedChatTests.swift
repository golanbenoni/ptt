import Foundation
import Testing
@testable import PttTalkLib

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
        key: sealed.key,
        ciphertextSha256: sealed.sha256
    )
    #expect(try EncryptedChatCodec.openAttachment(
        sealed.ciphertext,
        metadata: metadata,
        channelId: channelId,
        membershipEpoch: 7
    ) == plaintext)
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
    ]
    var reduced = ChatEventReducer.reduce(events, channelId: channel, localAci: bob)
    #expect(reduced.count == 1)
    #expect(reduced[0].displayText == "after")
    #expect(reduced[0].reactions[bob] == "👍")
    #expect(reduced[0].receipts["\(bob):1"] == .read)
    #expect(!reduced[0].isUnread)

    events.append(event(.delete, sender: alice, target: message.messageId, offset: 5))
    reduced = ChatEventReducer.reduce(events, channelId: channel, localAci: bob)
    #expect(reduced[0].isDeleted)
    #expect(reduced[0].displayText.isEmpty)
    #expect(reduced[0].reactions.isEmpty)
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
    let measuring = try SecureChatArchive(
        namespace: "test-chat-measure-\(UUID().uuidString)", directory: root,
        testKey: Data(repeating: 0x27, count: 32), maximumBytes: 100_000
    )
    try measuring.put(first, expiresAt: Date().addingTimeInterval(60))
    try measuring.put(second, expiresAt: Date().addingTimeInterval(60))
    let measuredBytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        .reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    try measuring.erase()
    let pruning = try SecureChatArchive(
        namespace: "test-chat-prune-\(UUID().uuidString)", directory: root,
        testKey: Data(repeating: 0x27, count: 32), maximumBytes: measuredBytes / 2 + 1
    )
    try pruning.put(first, expiresAt: Date().addingTimeInterval(60))
    try pruning.put(second, expiresAt: Date().addingTimeInterval(60))
    let retained = try pruning.messages(channelId: channel)
    #expect(retained.last?.messageId == second.messageId)
    #expect(retained.count < 2)

    try pruning.erase()
    #expect(!FileManager.default.fileExists(atPath: root.path))
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
