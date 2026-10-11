import Foundation
import Security

public extension Data {
    static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
}

// The archive probe uses an explicit test key, so it does not access Keychain.
// This minimal definition lets the production archive implementation run without
// linking the unrelated Rust media and libsignal static libraries.
final class KeychainVault {
    init(service: String) {}
    func get(_ account: String) throws -> Data? { nil }
    func put(_ account: String, _ value: Data) throws {}
    func deleteAll() throws {}
}

struct ChatRecipient: Equatable, Sendable {
    let aci: String
    let deviceId: Int
    let envelope: Data
}

let liveSignal = EncryptedLiveSignal(
    signalId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    channelId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
    membershipEpoch: 7,
    sentAt: Date(timeIntervalSince1970: 1_700_000_000),
    expiresAt: Date(timeIntervalSince1970: 1_700_000_010),
    kind: .typingStarted,
    threadRootId: UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!
)
let liveEncoded = try EncryptedLiveSignalCodec.encode(liveSignal)
let liveFrozen = "50545449010111111111222233334444555555555555aaaaaaaabbbbccccddddeeeeeeeeeeee" +
    "000000070000018bcfe568000000018bcfe58f1012345678123456789abcdef012345678"
precondition(liveEncoded.map { String(format: "%02x", $0) }.joined() == liveFrozen)
let liveDecoded = try EncryptedLiveSignalCodec.decode(liveEncoded)
precondition(liveDecoded == liveSignal)

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
let frozen = "50545443010100112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e8000000026869"
precondition(encoded.map { String(format: "%02x", $0) }.joined() == frozen)
let decoded = try EncryptedChatCodec.decode(
    encoded, senderAci: message.senderAci, senderDeviceId: message.senderDeviceId
)
precondition(decoded == message)

let waveformMessage = ChatMessage(
    messageId: message.messageId, channelId: message.channelId,
    membershipEpoch: message.membershipEpoch, sentAt: message.sentAt,
    senderAci: message.senderAci, senderDeviceId: message.senderDeviceId,
    kind: .voice, text: "",
    attachment: ChatAttachment(
        attachmentId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!,
        fileName: "voice.m4a", mimeType: "audio/mp4", plaintextBytes: 18,
        durationMs: 1_200, waveform: Data([8, 64, 127, 255]),
        key: Data(0..<32), ciphertextSha256: Data(32..<64)
    )
)
let waveformFrozen = "50545443020300112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b0090904000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff766f6963652e6d3461617564696f2f6d7034"
let waveformEncoded = try EncryptedChatCodec.encode(waveformMessage)
precondition(waveformEncoded.map { String(format: "%02x", $0) }.joined() == waveformFrozen)

let thumbnail = ChatThumbnail(
    thumbnailId: UUID(uuidString: "20314253-6475-4897-a8b9-cadbecfd0e1f")!,
    mimeType: "image/jpeg", plaintextBytes: 12, width: 320, height: 180,
    key: Data(64..<96), ciphertextSha256: Data(96..<128)
)
let thumbnailMessage = ChatMessage(
    messageId: message.messageId, channelId: message.channelId,
    membershipEpoch: message.membershipEpoch, sentAt: message.sentAt,
    senderAci: message.senderAci, senderDeviceId: message.senderDeviceId,
    kind: .video, text: "",
    attachment: ChatAttachment(
        attachmentId: UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!,
        fileName: "clip.mp4", mimeType: "video/mp4", plaintextBytes: 18,
        durationMs: 1_200, waveform: Data([8, 64, 127, 255]), thumbnail: thumbnail,
        key: Data(0..<32), ciphertextSha256: Data(32..<64)
    )
)
let thumbnailFrozen = "50545443030400112233445546778899aabbccddeeffffeeddccbbaa498887665544332211000000000700000000000003e800000000102132435465478798a9bacbdcedfe0f0000000000000012000004b00809040a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f08407fff2031425364754897a8b9cadbecfd0e1f0000000c014000b4404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f696d6167652f6a706567636c69702e6d7034766964656f2f6d7034"
let thumbnailEncoded = try EncryptedChatCodec.encode(thumbnailMessage)
precondition(thumbnailEncoded.map { String(format: "%02x", $0) }.joined() == thumbnailFrozen)
let thumbnailDecoded = try EncryptedChatCodec.decode(
    thumbnailEncoded, senderAci: message.senderAci, senderDeviceId: message.senderDeviceId
)
precondition(thumbnailDecoded == thumbnailMessage)

let attachmentId = UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
let plaintext = Data("private voice note".utf8)
let sealed = try EncryptedChatCodec.sealAttachment(
    plaintext,
    attachmentId: attachmentId,
    channelId: message.channelId,
    membershipEpoch: message.membershipEpoch,
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
let opened = try EncryptedChatCodec.openAttachment(
    sealed.ciphertext,
    metadata: metadata,
    channelId: message.channelId,
    membershipEpoch: message.membershipEpoch
)
precondition(opened == plaintext)

let previewPlaintext = Data("private preview".utf8)
let previewSealed = try EncryptedChatCodec.sealThumbnail(
    previewPlaintext, thumbnailId: thumbnail.thumbnailId, channelId: message.channelId,
    membershipEpoch: message.membershipEpoch, key: Data(0..<32)
)
let previewMetadata = ChatThumbnail(
    thumbnailId: thumbnail.thumbnailId, mimeType: "image/jpeg",
    plaintextBytes: Int32(previewPlaintext.count), width: 320, height: 180,
    key: previewSealed.key, ciphertextSha256: previewSealed.sha256
)
let previewOpened = try EncryptedChatCodec.openThumbnail(
    previewSealed.ciphertext, metadata: previewMetadata,
    channelId: message.channelId, membershipEpoch: message.membershipEpoch
)
precondition(previewOpened == previewPlaintext)
let localBundle = try EncryptedChatCodec.packAttachmentCiphertexts(
    attachment: sealed.ciphertext, thumbnail: previewSealed.ciphertext
)
let unpackedBundle = try EncryptedChatCodec.unpackAttachmentCiphertexts(localBundle)
precondition(unpackedBundle.attachment == sealed.ciphertext)
precondition(unpackedBundle.thumbnail == previewSealed.ciphertext)

var altered = sealed.ciphertext
altered[altered.count - 1] ^= 1
do {
    _ = try EncryptedChatCodec.openAttachment(
        altered,
        metadata: metadata,
        channelId: message.channelId,
        membershipEpoch: message.membershipEpoch
    )
    fatalError("tampered attachment was accepted")
} catch EncryptedChatError.attachmentIntegrityFailed {
    // Expected.
}

let unicode = String(repeating: "🔒", count: 100) + ".mov"
precondition(Data(EncryptedChatCodec.boundedUTF8(unicode, maximumBytes: 255).utf8).count <= 255)

let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: archiveRoot) }
func archiveMessage(_ seconds: TimeInterval) -> ChatMessage {
    ChatMessage(
        messageId: UUID(), channelId: message.channelId, membershipEpoch: 7,
        sentAt: Date().addingTimeInterval(seconds), senderAci: message.senderAci,
        senderDeviceId: 2, kind: .text, text: String(repeating: "private", count: 40)
    )
}
let first = archiveMessage(-2)
let second = archiveMessage(-1)
let archiveExpiry = Date(timeIntervalSince1970: 2_000_000_000)
let measuringArchive = try SecureChatArchive(
    namespace: "chat-probe-measure", directory: archiveRoot,
    testKey: Data(repeating: 0x27, count: 32), maximumBytes: 100_000
)
try measuringArchive.put(first, expiresAt: archiveExpiry)
try measuringArchive.put(second, expiresAt: archiveExpiry)
let recordSizes = try FileManager.default.contentsOfDirectory(
    at: archiveRoot, includingPropertiesForKeys: [.fileSizeKey]
)
    .filter { $0.lastPathComponent.hasPrefix("message-") && $0.pathExtension == "bin" }
    .map { Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
precondition(recordSizes.count == 2)
let singleRecordBudget = recordSizes.max()!
try measuringArchive.erase()
let pruningArchive = try SecureChatArchive(
    namespace: "chat-probe-prune", directory: archiveRoot,
    testKey: Data(repeating: 0x27, count: 32), maximumBytes: singleRecordBudget
)
try pruningArchive.put(first, expiresAt: archiveExpiry)
try pruningArchive.put(second, expiresAt: archiveExpiry)
let retained = try pruningArchive.messages(channelId: message.channelId)
precondition(retained.last?.messageId == second.messageId && retained.count < 2)
try pruningArchive.erase()
precondition(!FileManager.default.fileExists(atPath: archiveRoot.path))

// Delivery summaries exclude deleted messages and incoming messages (nil send state).
let deliveryItems = [ChatSendState.queued, .sending, .failed].map {
    ChatConversationMessage(message: message, sendState: $0)
}
let summary = ChatDeliverySummary(conversation: deliveryItems + [
    ChatConversationMessage(message: message),
    ChatConversationMessage(message: message, isDeleted: true, sendState: .failed),
])
precondition(summary.status == "1 queued · 1 sending · 1 failed" && summary.total == 3)
precondition(deliveryItems[0].canRetry && !deliveryItems[1].canRetry && deliveryItems[2].canRetry)
precondition(!ChatConversationMessage(message: message, sendState: .failed, deliveryBlockedByMembership: true).canRetry)
let retryEvent = ChatEvent.message(message)
precondition(ChatRetryPolicy.rejection(event: retryEvent, channelId: message.channelId,
    membershipEpoch: 7, localAci: message.senderAci, visible: true, lastErrorCode: nil) == nil)
precondition(ChatRetryPolicy.rejection(event: retryEvent, channelId: message.channelId,
    membershipEpoch: 8, localAci: message.senderAci, visible: true, lastErrorCode: nil) == .membershipChanged)
precondition(ChatRetryPolicy.rejection(event: retryEvent, channelId: UUID(),
    membershipEpoch: 7, localAci: message.senderAci, visible: true, lastErrorCode: nil) == .failed)

// Reopen the production encrypted archive and verify a failed attachment preserves
// its original event, ciphertext and envelopes. Updating one entry leaves others intact.
let deliveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: deliveryRoot) }
let testKey = Data(repeating: 0x38, count: 32)
var deliveryArchive = try SecureChatArchive(namespace: "delivery-probe", directory: deliveryRoot, testKey: testKey)
let attachmentEvent = ChatEvent.message(waveformMessage)
let recipient = ChatRecipient(aci: UUID().uuidString.lowercased(), deviceId: 1, envelope: Data([7, 8, 9]))
let otherChannel = UUID()
let otherMessage = ChatMessage(messageId: UUID(), channelId: otherChannel, membershipEpoch: 7,
    sentAt: Date(), senderAci: message.senderAci, senderDeviceId: 1, kind: .text, text: "Other chat")
let otherEvent = ChatEvent.message(otherMessage)
try deliveryArchive.putEvent(attachmentEvent, expiresAt: archiveExpiry, attachmentCiphertext: localBundle)
try deliveryArchive.putOutbox(event: attachmentEvent, recipients: [recipient], expiresAt: archiveExpiry)
try deliveryArchive.putEvent(otherEvent, expiresAt: archiveExpiry)
try deliveryArchive.putOutbox(event: otherEvent, recipients: [], expiresAt: archiveExpiry)
try deliveryArchive.markOutbox(attachmentEvent.eventId, state: .failed, errorCode: "delivery_failed")
deliveryArchive = try SecureChatArchive(namespace: "delivery-reopen", directory: deliveryRoot, testKey: testKey)
let restored = try deliveryArchive.outbox()
precondition(restored.count == 2)
let restoredAttachment = restored.first { $0.event.eventId == attachmentEvent.eventId }!
precondition(restoredAttachment.event == attachmentEvent && restoredAttachment.recipients == [recipient])
precondition(restoredAttachment.state == .failed && restoredAttachment.lastErrorCode == "delivery_failed")
let restoredCiphertext = try deliveryArchive.attachmentCiphertext(messageId: attachmentEvent.eventId)
precondition(restoredCiphertext == localBundle)
let unaffected = restored.first { $0.event.eventId == otherEvent.eventId }!
try deliveryArchive.markOutbox(attachmentEvent.eventId, state: .sending)
try deliveryArchive.removeOutbox(attachmentEvent.eventId)
let remaining = try deliveryArchive.outbox()
precondition(remaining == [unaffected])
let firstConversation = try deliveryArchive.conversation(channelId: message.channelId, localAci: message.senderAci)
let otherConversation = try deliveryArchive.conversation(channelId: otherChannel, localAci: message.senderAci)
precondition(firstConversation.count == 1 && otherConversation.count == 1)

print("Swift encrypted chat codec, delivery policy and durable archive probe passed")
