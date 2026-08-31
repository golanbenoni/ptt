import CryptoKit
import Foundation

public enum ChatContentKind: UInt8, Codable, CaseIterable, Sendable {
    case text = 1
    case file = 2
    case voice = 3
    case video = 4
}

public struct ChatAttachment: Codable, Equatable, Sendable {
    public let attachmentId: UUID
    public let fileName: String
    public let mimeType: String
    public let plaintextBytes: Int64
    public let durationMs: Int32
    public let key: Data
    public let ciphertextSha256: Data

    public init(
        attachmentId: UUID,
        fileName: String,
        mimeType: String,
        plaintextBytes: Int64,
        durationMs: Int32 = 0,
        key: Data,
        ciphertextSha256: Data
    ) {
        self.attachmentId = attachmentId
        self.fileName = fileName
        self.mimeType = mimeType
        self.plaintextBytes = plaintextBytes
        self.durationMs = durationMs
        self.key = key
        self.ciphertextSha256 = ciphertextSha256
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let messageId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int32
    public let sentAt: Date
    public let senderAci: String
    public let senderDeviceId: Int
    public let kind: ChatContentKind
    public let text: String
    public let attachment: ChatAttachment?
    public var id: UUID { messageId }

    public init(
        messageId: UUID,
        channelId: UUID,
        membershipEpoch: Int32,
        sentAt: Date,
        senderAci: String,
        senderDeviceId: Int,
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment? = nil
    ) {
        self.messageId = messageId
        self.channelId = channelId
        self.membershipEpoch = membershipEpoch
        self.sentAt = sentAt
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.kind = kind
        self.text = text
        self.attachment = attachment
    }
}

public enum EncryptedChatCodec {
    private static let magic = Data("PTTC".utf8)
    private static let attachmentMagic = Data("PTTA".utf8)
    public static let maximumTextBytes = 4_096
    public static let maximumAttachmentBytes = 25 * 1_024 * 1_024

    static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard Data(value.utf8).count > maximumBytes else { return value }
        var result = ""
        for character in value {
            guard Data((result + String(character)).utf8).count <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }

    public static func encode(_ message: ChatMessage) throws -> Data {
        guard message.membershipEpoch > 0, (1...2).contains(message.senderDeviceId),
              UUID(uuidString: message.senderAci) != nil else { throw EncryptedChatError.invalidMessage }
        let text = Data(message.text.utf8)
        guard text.count <= maximumTextBytes else { throw EncryptedChatError.textTooLarge }
        if message.kind == .text, message.attachment != nil { throw EncryptedChatError.invalidMessage }
        if message.kind != .text, message.attachment == nil { throw EncryptedChatError.invalidMessage }
        var output = magic
        output.append(1)
        output.append(message.kind.rawValue)
        output.append(contentsOf: uuidBytes(message.messageId))
        output.append(contentsOf: uuidBytes(message.channelId))
        append(message.membershipEpoch, to: &output)
        append(Int64(message.sentAt.timeIntervalSince1970 * 1_000), to: &output)
        append(UInt32(text.count), to: &output)
        output.append(text)
        guard let attachment = message.attachment else { return output }
        let name = Data(attachment.fileName.utf8)
        let mime = Data(attachment.mimeType.utf8)
        guard !name.isEmpty, name.count <= 255, !mime.isEmpty, mime.count <= 127,
              (1...Int64(maximumAttachmentBytes)).contains(attachment.plaintextBytes),
              (0...600_000).contains(attachment.durationMs), attachment.key.count == 32,
              attachment.ciphertextSha256.count == 32 else { throw EncryptedChatError.invalidAttachment }
        output.append(contentsOf: uuidBytes(attachment.attachmentId))
        append(attachment.plaintextBytes, to: &output)
        append(attachment.durationMs, to: &output)
        output.append(UInt8(name.count))
        output.append(UInt8(mime.count))
        output.append(attachment.key)
        output.append(attachment.ciphertextSha256)
        output.append(name)
        output.append(mime)
        return output
    }

    public static func decode(
        _ bytes: Data,
        senderAci: String,
        senderDeviceId: Int
    ) throws -> ChatMessage {
        guard bytes.count >= 54, bytes.prefix(4) == magic, bytes[4] == 1,
              let kind = ChatContentKind(rawValue: bytes[5]), (1...2).contains(senderDeviceId),
              UUID(uuidString: senderAci) != nil else { throw EncryptedChatError.invalidMessage }
        var offset = 6
        let messageId = try readUUID(bytes, &offset)
        let channelId = try readUUID(bytes, &offset)
        let epoch: Int32 = try read(bytes, &offset)
        let sentAtMs: Int64 = try read(bytes, &offset)
        let textCount = Int(try read(bytes, &offset) as UInt32)
        guard epoch > 0, textCount <= maximumTextBytes, offset + textCount <= bytes.count else {
            throw EncryptedChatError.invalidMessage
        }
        guard let text = String(data: bytes.subdata(in: offset..<(offset + textCount)), encoding: .utf8) else {
            throw EncryptedChatError.invalidMessage
        }
        offset += textCount
        var attachment: ChatAttachment?
        if kind == .text {
            guard offset == bytes.count else { throw EncryptedChatError.invalidMessage }
        } else {
            guard offset + 16 + 8 + 4 + 2 + 64 <= bytes.count else { throw EncryptedChatError.invalidAttachment }
            let attachmentId = try readUUID(bytes, &offset)
            let plaintextBytes: Int64 = try read(bytes, &offset)
            let durationMs: Int32 = try read(bytes, &offset)
            let nameCount = Int(bytes[offset]); offset += 1
            let mimeCount = Int(bytes[offset]); offset += 1
            let key = bytes.subdata(in: offset..<(offset + 32)); offset += 32
            let digest = bytes.subdata(in: offset..<(offset + 32)); offset += 32
            guard nameCount > 0, mimeCount > 0, offset + nameCount + mimeCount == bytes.count,
                  (1...Int64(maximumAttachmentBytes)).contains(plaintextBytes),
                  (0...600_000).contains(durationMs),
                  let name = String(data: bytes.subdata(in: offset..<(offset + nameCount)), encoding: .utf8)
            else { throw EncryptedChatError.invalidAttachment }
            offset += nameCount
            guard let mime = String(data: bytes.subdata(in: offset..<(offset + mimeCount)), encoding: .utf8) else {
                throw EncryptedChatError.invalidAttachment
            }
            attachment = ChatAttachment(
                attachmentId: attachmentId,
                fileName: name,
                mimeType: mime,
                plaintextBytes: plaintextBytes,
                durationMs: durationMs,
                key: key,
                ciphertextSha256: digest
            )
        }
        return ChatMessage(
            messageId: messageId,
            channelId: channelId,
            membershipEpoch: epoch,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMs) / 1_000),
            senderAci: senderAci.lowercased(),
            senderDeviceId: senderDeviceId,
            kind: kind,
            text: text,
            attachment: attachment
        )
    }

    public static func sealAttachment(
        _ plaintext: Data,
        attachmentId: UUID,
        channelId: UUID,
        membershipEpoch: Int32,
        key: Data = .random(count: 32)
    ) throws -> (ciphertext: Data, key: Data, sha256: Data) {
        guard !plaintext.isEmpty, plaintext.count <= maximumAttachmentBytes, key.count == 32,
              membershipEpoch > 0 else { throw EncryptedChatError.invalidAttachment }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            authenticating: attachmentAad(attachmentId, channelId, membershipEpoch)
        )
        guard let combined = sealed.combined else { throw EncryptedChatError.invalidAttachment }
        var ciphertext = attachmentMagic
        ciphertext.append(1)
        ciphertext.append(combined)
        return (ciphertext, key, Data(SHA256.hash(data: ciphertext)))
    }

    public static func openAttachment(
        _ ciphertext: Data,
        metadata: ChatAttachment,
        channelId: UUID,
        membershipEpoch: Int32
    ) throws -> Data {
        guard ciphertext.count > 5, ciphertext.prefix(4) == attachmentMagic, ciphertext[4] == 1,
              Data(SHA256.hash(data: ciphertext)) == metadata.ciphertextSha256 else {
            throw EncryptedChatError.attachmentIntegrityFailed
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(5))
        let plaintext = try AES.GCM.open(
            box,
            using: SymmetricKey(data: metadata.key),
            authenticating: attachmentAad(metadata.attachmentId, channelId, membershipEpoch)
        )
        guard plaintext.count == metadata.plaintextBytes else { throw EncryptedChatError.attachmentIntegrityFailed }
        return plaintext
    }

    private static func attachmentAad(_ attachmentId: UUID, _ channelId: UUID, _ epoch: Int32) -> Data {
        var value = Data("PTT-CHAT-ATTACHMENT-V1".utf8)
        value.append(contentsOf: uuidBytes(attachmentId))
        value.append(contentsOf: uuidBytes(channelId))
        append(epoch, to: &value)
        return value
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        withUnsafeBytes(of: value.uuid) { Array($0) }
    }

    private static func readUUID(_ data: Data, _ offset: inout Int) throws -> UUID {
        guard offset + 16 <= data.count else { throw EncryptedChatError.invalidMessage }
        let bytes = [UInt8](data[offset..<(offset + 16)])
        offset += 16
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, _ offset: inout Int) throws -> T {
        guard offset + MemoryLayout<T>.size <= data.count else { throw EncryptedChatError.invalidMessage }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
        offset += MemoryLayout<T>.size
        return T(bigEndian: value)
    }
}

public enum EncryptedChatError: Error, Equatable {
    case invalidMessage
    case textTooLarge
    case invalidAttachment
    case attachmentIntegrityFailed
}
