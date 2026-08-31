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
let measuringArchive = try SecureChatArchive(
    namespace: "chat-probe-measure", directory: archiveRoot,
    testKey: Data(repeating: 0x27, count: 32), maximumBytes: 100_000
)
try measuringArchive.put(first, expiresAt: Date().addingTimeInterval(60))
try measuringArchive.put(second, expiresAt: Date().addingTimeInterval(60))
let measuredBytes = try FileManager.default.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: [.fileSizeKey])
    .reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
try measuringArchive.erase()
let pruningArchive = try SecureChatArchive(
    namespace: "chat-probe-prune", directory: archiveRoot,
    testKey: Data(repeating: 0x27, count: 32), maximumBytes: measuredBytes / 2 + 1
)
try pruningArchive.put(first, expiresAt: Date().addingTimeInterval(60))
try pruningArchive.put(second, expiresAt: Date().addingTimeInterval(60))
let retained = try pruningArchive.messages(channelId: message.channelId)
precondition(retained.last?.messageId == second.messageId && retained.count < 2)
try pruningArchive.erase()
precondition(!FileManager.default.fileExists(atPath: archiveRoot.path))

print("Swift encrypted chat codec and secure archive probe passed")
