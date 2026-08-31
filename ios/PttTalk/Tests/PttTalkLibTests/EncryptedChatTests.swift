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
