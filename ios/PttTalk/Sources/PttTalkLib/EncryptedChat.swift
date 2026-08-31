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
    /// Up to 64 normalized amplitude samples. It is carried inside the
    /// pairwise-encrypted message envelope and is never visible to the service.
    public let waveform: Data
    public let key: Data
    public let ciphertextSha256: Data

    public init(
        attachmentId: UUID,
        fileName: String,
        mimeType: String,
        plaintextBytes: Int64,
        durationMs: Int32 = 0,
        waveform: Data = Data(),
        key: Data,
        ciphertextSha256: Data
    ) {
        self.attachmentId = attachmentId
        self.fileName = fileName
        self.mimeType = mimeType
        self.plaintextBytes = plaintextBytes
        self.durationMs = durationMs
        self.waveform = waveform
        self.key = key
        self.ciphertextSha256 = ciphertextSha256
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentId, fileName, mimeType, plaintextBytes, durationMs, waveform, key, ciphertextSha256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachmentId = try values.decode(UUID.self, forKey: .attachmentId)
        fileName = try values.decode(String.self, forKey: .fileName)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        plaintextBytes = try values.decode(Int64.self, forKey: .plaintextBytes)
        durationMs = try values.decode(Int32.self, forKey: .durationMs)
        waveform = try values.decodeIfPresent(Data.self, forKey: .waveform) ?? Data()
        key = try values.decode(Data.self, forKey: .key)
        ciphertextSha256 = try values.decode(Data.self, forKey: .ciphertextSha256)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(attachmentId, forKey: .attachmentId)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(mimeType, forKey: .mimeType)
        try values.encode(plaintextBytes, forKey: .plaintextBytes)
        try values.encode(durationMs, forKey: .durationMs)
        try values.encode(waveform, forKey: .waveform)
        try values.encode(key, forKey: .key)
        try values.encode(ciphertextSha256, forKey: .ciphertextSha256)
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

/// End-to-end encrypted mutations and receipts share one causal event format.
/// The control service treats the encoded event as opaque bytes.
public enum ChatEventKind: UInt8, Codable, CaseIterable, Sendable {
    case message = 1
    case delivered = 2
    case read = 3
    case played = 4
    case reaction = 5
    case removeReaction = 6
    case edit = 7
    case delete = 8
    case pin = 9
    case unpin = 10
}

public struct ChatEvent: Codable, Equatable, Identifiable, Sendable {
    public let eventId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int32
    public let sentAt: Date
    public let senderAci: String
    public let senderDeviceId: Int
    public let kind: ChatEventKind
    public let targetMessageId: UUID?
    public let replyToMessageId: UUID?
    public let value: String
    public let message: ChatMessage?
    public var id: UUID { eventId }

    public init(
        eventId: UUID,
        channelId: UUID,
        membershipEpoch: Int32,
        sentAt: Date,
        senderAci: String,
        senderDeviceId: Int,
        kind: ChatEventKind,
        targetMessageId: UUID? = nil,
        replyToMessageId: UUID? = nil,
        value: String = "",
        message: ChatMessage? = nil
    ) {
        self.eventId = eventId
        self.channelId = channelId
        self.membershipEpoch = membershipEpoch
        self.sentAt = sentAt
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.kind = kind
        self.targetMessageId = targetMessageId
        self.replyToMessageId = replyToMessageId
        self.value = value
        self.message = message
    }

    public static func message(_ message: ChatMessage, replyTo: UUID? = nil) -> ChatEvent {
        ChatEvent(
            eventId: message.messageId,
            channelId: message.channelId,
            membershipEpoch: message.membershipEpoch,
            sentAt: message.sentAt,
            senderAci: message.senderAci,
            senderDeviceId: message.senderDeviceId,
            kind: .message,
            replyToMessageId: replyTo,
            message: message
        )
    }
}

public enum ChatReceiptState: Int, Codable, Comparable, Sendable {
    case delivered = 1
    case read = 2
    case played = 3

    public static func < (lhs: ChatReceiptState, rhs: ChatReceiptState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ChatSendState: String, Codable, Equatable, Sendable {
    case queued
    case sending
    case failed
    case sent
    case delivered
    case read
    case played
}

public struct ChatConversationMessage: Equatable, Identifiable, Sendable {
    public let message: ChatMessage
    public let replyToMessageId: UUID?
    public let editedText: String?
    public let isDeleted: Bool
    public let reactions: [String: String]
    public let receipts: [String: ChatReceiptState]
    public let isUnread: Bool
    public let isPinned: Bool
    public let isStarred: Bool
    public let sendState: ChatSendState?
    public var id: UUID { message.messageId }
    public var displayText: String { isDeleted ? "" : (editedText ?? message.text) }

    public init(
        message: ChatMessage,
        replyToMessageId: UUID? = nil,
        editedText: String? = nil,
        isDeleted: Bool = false,
        reactions: [String: String] = [:],
        receipts: [String: ChatReceiptState] = [:],
        isUnread: Bool = false,
        isPinned: Bool = false,
        isStarred: Bool = false,
        sendState: ChatSendState? = nil
    ) {
        self.message = message
        self.replyToMessageId = replyToMessageId
        self.editedText = editedText
        self.isDeleted = isDeleted
        self.reactions = reactions
        self.receipts = receipts
        self.isUnread = isUnread
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.sendState = sendState
    }
}

/// Deterministically materializes an encrypted event log. Unauthorized edits
/// and deletes fail closed on every client even if a channel member creates a
/// syntactically valid event.
public enum ChatEventReducer {
    public static func reduce(
        _ events: [ChatEvent],
        channelId: UUID,
        localAci: String
    ) -> [ChatConversationMessage] {
        let ordered = events
            .filter { $0.channelId == channelId }
            .sorted {
                if $0.sentAt != $1.sentAt { return $0.sentAt < $1.sentAt }
                return $0.eventId.uuidString < $1.eventId.uuidString
            }
        var states: [UUID: MutableConversationState] = [:]
        for event in ordered where event.kind == .message {
            guard let message = event.message, states[message.messageId] == nil else { continue }
            states[message.messageId] = MutableConversationState(message: message, replyTo: event.replyToMessageId)
        }
        for event in ordered where event.kind != .message {
            guard let target = event.targetMessageId, var state = states[target],
                  event.sentAt >= state.message.sentAt else { continue }
            let source = "\(event.senderAci.lowercased()):\(event.senderDeviceId)"
            switch event.kind {
            case .message:
                break
            case .edit:
                guard event.senderAci.caseInsensitiveCompare(state.message.senderAci) == .orderedSame,
                      !state.deleted else { continue }
                state.editedText = event.value
            case .delete:
                guard event.senderAci.caseInsensitiveCompare(state.message.senderAci) == .orderedSame else { continue }
                state.deleted = true
                state.editedText = nil
                state.reactions.removeAll()
                state.pinned = false
            case .reaction:
                guard !state.deleted else { continue }
                state.reactions[event.senderAci.lowercased()] = event.value
            case .removeReaction:
                state.reactions.removeValue(forKey: event.senderAci.lowercased())
            case .delivered:
                state.receipts[source] = max(state.receipts[source] ?? .delivered, .delivered)
            case .read:
                state.receipts[source] = max(state.receipts[source] ?? .delivered, .read)
            case .played:
                state.receipts[source] = max(state.receipts[source] ?? .delivered, .played)
            case .pin:
                guard !state.deleted else { continue }
                state.pinned = true
            case .unpin:
                state.pinned = false
            }
            states[target] = state
        }
        let canonicalLocalAci = localAci.lowercased()
        return states.values.map { state in
            let locallyRead = state.message.senderAci.lowercased() == canonicalLocalAci ||
                state.receipts.contains { key, receipt in
                    key.hasPrefix("\(canonicalLocalAci):") && receipt >= .read
                }
            return ChatConversationMessage(
                message: state.message,
                replyToMessageId: state.replyTo,
                editedText: state.editedText,
                isDeleted: state.deleted,
                reactions: state.reactions,
                receipts: state.receipts,
                isUnread: !locallyRead,
                isPinned: state.pinned
            )
        }.sorted {
            if $0.message.sentAt != $1.message.sentAt { return $0.message.sentAt < $1.message.sentAt }
            return $0.message.messageId.uuidString < $1.message.messageId.uuidString
        }
    }

    private struct MutableConversationState {
        let message: ChatMessage
        let replyTo: UUID?
        var editedText: String?
        var deleted = false
        var reactions: [String: String] = [:]
        var receipts: [String: ChatReceiptState] = [:]
        var pinned = false

        init(message: ChatMessage, replyTo: UUID?) {
            self.message = message
            self.replyTo = replyTo
        }
    }
}

public enum EncryptedChatCodec {
    private static let magic = Data("PTTC".utf8)
    private static let eventMagic = Data("PTTE".utf8)
    private static let attachmentMagic = Data("PTTA".utf8)
    public static let maximumTextBytes = 4_096
    public static let maximumAttachmentBytes = 25 * 1_024 * 1_024
    public static let maximumReactionBytes = 64

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
        output.append(message.attachment == nil ? 1 : 2)
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
              attachment.waveform.count <= 64,
              attachment.ciphertextSha256.count == 32 else { throw EncryptedChatError.invalidAttachment }
        output.append(contentsOf: uuidBytes(attachment.attachmentId))
        append(attachment.plaintextBytes, to: &output)
        append(attachment.durationMs, to: &output)
        output.append(UInt8(name.count))
        output.append(UInt8(mime.count))
        output.append(UInt8(attachment.waveform.count))
        output.append(attachment.key)
        output.append(attachment.ciphertextSha256)
        output.append(attachment.waveform)
        output.append(name)
        output.append(mime)
        return output
    }

    public static func decode(
        _ bytes: Data,
        senderAci: String,
        senderDeviceId: Int
    ) throws -> ChatMessage {
        guard bytes.count >= 54, bytes.prefix(4) == magic, (1...2).contains(bytes[4]),
              let kind = ChatContentKind(rawValue: bytes[5]), (1...2).contains(senderDeviceId),
              UUID(uuidString: senderAci) != nil else { throw EncryptedChatError.invalidMessage }
        let version = bytes[4]
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
            let lengthBytes = version == 2 ? 3 : 2
            guard offset + 16 + 8 + 4 + lengthBytes + 64 <= bytes.count else { throw EncryptedChatError.invalidAttachment }
            let attachmentId = try readUUID(bytes, &offset)
            let plaintextBytes: Int64 = try read(bytes, &offset)
            let durationMs: Int32 = try read(bytes, &offset)
            let nameCount = Int(bytes[offset]); offset += 1
            let mimeCount = Int(bytes[offset]); offset += 1
            let waveformCount = version == 2 ? Int(bytes[offset]) : 0
            if version == 2 { offset += 1 }
            let key = bytes.subdata(in: offset..<(offset + 32)); offset += 32
            let digest = bytes.subdata(in: offset..<(offset + 32)); offset += 32
            guard nameCount > 0, mimeCount > 0, waveformCount <= 64,
                  offset + waveformCount + nameCount + mimeCount == bytes.count,
                  (1...Int64(maximumAttachmentBytes)).contains(plaintextBytes),
                  (0...600_000).contains(durationMs)
            else { throw EncryptedChatError.invalidAttachment }
            let waveform = bytes.subdata(in: offset..<(offset + waveformCount)); offset += waveformCount
            guard let name = String(data: bytes.subdata(in: offset..<(offset + nameCount)), encoding: .utf8)
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
                waveform: waveform,
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

    public static func encodeEvent(_ event: ChatEvent) throws -> Data {
        guard event.membershipEpoch > 0, (1...2).contains(event.senderDeviceId),
              event.senderAci == event.senderAci.lowercased(),
              UUID(uuidString: event.senderAci) != nil else { throw EncryptedChatError.invalidEvent }
        let payload: Data
        switch event.kind {
        case .message:
            guard let message = event.message, event.targetMessageId == nil, event.value.isEmpty,
                  event.eventId == message.messageId, event.channelId == message.channelId,
                  event.membershipEpoch == message.membershipEpoch,
                  Int64(event.sentAt.timeIntervalSince1970 * 1_000) == Int64(message.sentAt.timeIntervalSince1970 * 1_000),
                  event.senderAci.lowercased() == message.senderAci.lowercased(),
                  event.senderDeviceId == message.senderDeviceId
            else { throw EncryptedChatError.invalidEvent }
            payload = try encode(message)
        case .delivered, .read, .played, .delete, .pin, .unpin:
            guard event.message == nil, event.targetMessageId != nil,
                  event.replyToMessageId == nil, event.value.isEmpty else {
                throw EncryptedChatError.invalidEvent
            }
            payload = Data()
        case .reaction:
            let value = Data(event.value.utf8)
            guard event.message == nil, event.targetMessageId != nil,
                  event.replyToMessageId == nil, !value.isEmpty,
                  value.count <= maximumReactionBytes else { throw EncryptedChatError.invalidEvent }
            payload = value
        case .removeReaction:
            guard event.message == nil, event.targetMessageId != nil,
                  event.replyToMessageId == nil, event.value.isEmpty else {
                throw EncryptedChatError.invalidEvent
            }
            payload = Data()
        case .edit:
            let value = Data(event.value.utf8)
            guard event.message == nil, event.targetMessageId != nil,
                  event.replyToMessageId == nil, !value.isEmpty,
                  value.count <= maximumTextBytes else { throw EncryptedChatError.invalidEvent }
            payload = value
        }
        guard payload.count <= Int(UInt32.max) else { throw EncryptedChatError.invalidEvent }
        var output = eventMagic
        output.append(1)
        output.append(event.kind.rawValue)
        output.append(contentsOf: uuidBytes(event.eventId))
        output.append(contentsOf: uuidBytes(event.channelId))
        append(event.membershipEpoch, to: &output)
        append(Int64(event.sentAt.timeIntervalSince1970 * 1_000), to: &output)
        output.append(contentsOf: optionalUuidBytes(event.targetMessageId))
        output.append(contentsOf: optionalUuidBytes(event.replyToMessageId))
        append(UInt32(payload.count), to: &output)
        output.append(payload)
        return output
    }

    public static func decodeEvent(
        _ bytes: Data,
        senderAci: String,
        senderDeviceId: Int
    ) throws -> ChatEvent {
        guard bytes.count >= 86, bytes.prefix(4) == eventMagic, bytes[4] == 1,
              let kind = ChatEventKind(rawValue: bytes[5]), (1...2).contains(senderDeviceId),
              UUID(uuidString: senderAci) != nil else { throw EncryptedChatError.invalidEvent }
        var offset = 6
        let eventId = try readUUID(bytes, &offset)
        let channelId = try readUUID(bytes, &offset)
        let epoch: Int32 = try read(bytes, &offset)
        let sentAtMs: Int64 = try read(bytes, &offset)
        let target = try readOptionalUUID(bytes, &offset)
        let reply = try readOptionalUUID(bytes, &offset)
        let payloadCount = Int(try read(bytes, &offset) as UInt32)
        guard eventId != zeroUuid, channelId != zeroUuid, epoch > 0,
              payloadCount <= bytes.count - offset, offset + payloadCount == bytes.count else {
            throw EncryptedChatError.invalidEvent
        }
        let payload = bytes.subdata(in: offset..<bytes.count)
        let message: ChatMessage?
        let value: String
        if kind == .message {
            message = try decode(payload, senderAci: senderAci, senderDeviceId: senderDeviceId)
            value = ""
        } else {
            message = nil
            guard let decoded = String(data: payload, encoding: .utf8) else {
                throw EncryptedChatError.invalidEvent
            }
            value = decoded
        }
        let event = ChatEvent(
            eventId: eventId,
            channelId: channelId,
            membershipEpoch: epoch,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMs) / 1_000),
            senderAci: senderAci.lowercased(),
            senderDeviceId: senderDeviceId,
            kind: kind,
            targetMessageId: target,
            replyToMessageId: reply,
            value: value,
            message: message
        )
        guard try encodeEvent(event) == bytes else { throw EncryptedChatError.invalidEvent }
        return event
    }

    /// Lets upgraded clients receive the v1 message format while all newly
    /// generated mutations and receipts use the event format.
    public static func decodeEventOrLegacyMessage(
        _ bytes: Data,
        senderAci: String,
        senderDeviceId: Int
    ) throws -> ChatEvent {
        if bytes.prefix(4) == magic {
            return .message(try decode(bytes, senderAci: senderAci, senderDeviceId: senderDeviceId))
        }
        return try decodeEvent(bytes, senderAci: senderAci, senderDeviceId: senderDeviceId)
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

    private static let zeroUuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func optionalUuidBytes(_ value: UUID?) -> [UInt8] {
        uuidBytes(value ?? zeroUuid)
    }

    private static func readOptionalUUID(_ data: Data, _ offset: inout Int) throws -> UUID? {
        let value = try readUUID(data, &offset)
        return value == zeroUuid ? nil : value
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
    case invalidEvent
    case textTooLarge
    case invalidAttachment
    case attachmentIntegrityFailed
    case deliveryInterrupted
}
