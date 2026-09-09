import Foundation

public enum EncryptedCallKeyMessageKind: UInt8, Sendable {
    case announcement = 1
    case acknowledgement = 2
}

public struct EncryptedCallKeyMessage: Equatable, Identifiable, Sendable {
    public let messageId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int32
    public let callId: UUID
    public let callEpoch: Int32
    public let kind: EncryptedCallKeyMessageKind
    public let participantIdentity: String
    public let key: Data?
    public let senderAci: String
    public let senderDeviceId: Int
    public var id: UUID { messageId }

    public init(
        messageId: UUID = UUID(), channelId: UUID, membershipEpoch: Int32,
        callId: UUID, callEpoch: Int32, kind: EncryptedCallKeyMessageKind,
        participantIdentity: String, key: Data?, senderAci: String = "", senderDeviceId: Int = 0
    ) {
        self.messageId = messageId
        self.channelId = channelId
        self.membershipEpoch = membershipEpoch
        self.callId = callId
        self.callEpoch = callEpoch
        self.kind = kind
        self.participantIdentity = participantIdentity
        self.key = key
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
    }
}

public enum EncryptedCallKeyCodec {
    private static let magic = Data("PTTC".utf8)
    private static let version: UInt8 = 1
    private static let zeroUuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public static func encode(_ message: EncryptedCallKeyMessage) throws -> Data {
        guard message.messageId != zeroUuid, message.channelId != zeroUuid, message.callId != zeroUuid,
              message.membershipEpoch > 0, message.callEpoch > 0,
              let identity = message.participantIdentity.data(using: .utf8),
              (16...128).contains(identity.count),
              (message.kind == .announcement ? message.key?.count == 32 : message.key?.count == 16) else {
            throw EncryptedCallMediaError.invalidKey
        }
        var output = magic
        output.append(version)
        output.append(message.kind.rawValue)
        output.append(contentsOf: uuidBytes(message.messageId))
        output.append(contentsOf: uuidBytes(message.channelId))
        output.append(contentsOf: uuidBytes(message.callId))
        append(message.membershipEpoch, to: &output)
        append(message.callEpoch, to: &output)
        output.append(UInt8(identity.count))
        output.append(identity)
        output.append(message.key ?? Data())
        return output
    }

    public static func decode(_ bytes: Data, senderAci: String, senderDeviceId: Int) throws -> EncryptedCallKeyMessage {
        guard bytes.count >= 63, bytes.prefix(4) == magic, bytes[4] == version,
              let kind = EncryptedCallKeyMessageKind(rawValue: bytes[5]),
              UUID(uuidString: senderAci) != nil, (1...2).contains(senderDeviceId) else {
            throw EncryptedCallMediaError.invalidKey
        }
        var offset = 6
        let messageId = try readUuid(bytes, &offset)
        let channelId = try readUuid(bytes, &offset)
        let callId = try readUuid(bytes, &offset)
        let membershipEpoch = try readInt32(bytes, &offset)
        let callEpoch = try readInt32(bytes, &offset)
        guard offset < bytes.count else { throw EncryptedCallMediaError.invalidKey }
        let identityCount = Int(bytes[offset]); offset += 1
        guard (16...128).contains(identityCount), offset + identityCount <= bytes.count,
              let identity = String(data: bytes[offset..<offset + identityCount], encoding: .utf8) else {
            throw EncryptedCallMediaError.invalidKey
        }
        offset += identityCount
        let key = Data(bytes[offset...])
        guard membershipEpoch > 0, callEpoch > 0,
              (kind == .announcement ? key.count == 32 : key.count == 16) else {
            throw EncryptedCallMediaError.invalidKey
        }
        let decoded = EncryptedCallKeyMessage(
            messageId: messageId, channelId: channelId, membershipEpoch: membershipEpoch,
            callId: callId, callEpoch: callEpoch, kind: kind,
            participantIdentity: identity, key: key,
            senderAci: senderAci.lowercased(), senderDeviceId: senderDeviceId
        )
        guard try encode(decoded) == bytes else { throw EncryptedCallMediaError.invalidKey }
        return decoded
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        withUnsafeBytes(of: value.uuid) { Array($0) }
    }

    private static func append(_ value: Int32, to output: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { output.append(contentsOf: $0) }
    }

    private static func readUuid(_ bytes: Data, _ offset: inout Int) throws -> UUID {
        guard offset + 16 <= bytes.count else { throw EncryptedCallMediaError.invalidKey }
        let raw = Array(bytes[offset..<offset + 16]); offset += 16
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }

    private static func readInt32(_ bytes: Data, _ offset: inout Int) throws -> Int32 {
        guard offset + 4 <= bytes.count else { throw EncryptedCallMediaError.invalidKey }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return Int32(bitPattern: value)
    }
}

/// Keychain-backed local inbox format used to hand call coordination safely across process restarts.
enum EncryptedCallKeyQueueCodec {
    private static let magic = Data("PTTQ".utf8)
    private static let version: UInt8 = 1
    static let maximumMessages = 128

    static func encode(_ messages: [EncryptedCallKeyMessage]) throws -> Data {
        guard messages.count <= maximumMessages else { throw EncryptedCallMediaError.invalidKey }
        let rows = try messages.map { message -> (EncryptedCallKeyMessage, Data, UUID) in
            guard let sender = UUID(uuidString: message.senderAci), (1...2).contains(message.senderDeviceId)
            else { throw EncryptedCallMediaError.invalidKey }
            return (message, try EncryptedCallKeyCodec.encode(message), sender)
        }
        var output = magic
        output.append(version)
        append(UInt16(rows.count), to: &output)
        for (message, body, sender) in rows {
            guard body.count <= Int(UInt16.max) else { throw EncryptedCallMediaError.invalidKey }
            withUnsafeBytes(of: sender.uuid) { output.append(contentsOf: $0) }
            output.append(UInt8(message.senderDeviceId))
            append(UInt16(body.count), to: &output)
            output.append(body)
        }
        return output
    }

    static func decode(_ bytes: Data?) throws -> [EncryptedCallKeyMessage] {
        guard let bytes, !bytes.isEmpty else { return [] }
        guard bytes.count >= 7, bytes.prefix(4) == magic, bytes[4] == version else {
            throw EncryptedCallMediaError.invalidKey
        }
        var offset = 5
        let count = Int(try readUInt16(bytes, &offset))
        guard count <= maximumMessages else { throw EncryptedCallMediaError.invalidKey }
        var messages: [EncryptedCallKeyMessage] = []
        messages.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 19 <= bytes.count else { throw EncryptedCallMediaError.invalidKey }
            let raw = Array(bytes[offset..<offset + 16]); offset += 16
            let sender = UUID(uuid: (
                raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
            )).uuidString.lowercased()
            let deviceId = Int(bytes[offset]); offset += 1
            let size = Int(try readUInt16(bytes, &offset))
            guard (1...2).contains(deviceId), (63...255).contains(size), offset + size <= bytes.count
            else { throw EncryptedCallMediaError.invalidKey }
            let body = Data(bytes[offset..<offset + size]); offset += size
            messages.append(try EncryptedCallKeyCodec.decode(
                body, senderAci: sender, senderDeviceId: deviceId
            ))
        }
        guard offset == bytes.count else { throw EncryptedCallMediaError.invalidKey }
        return messages
    }

    private static func append(_ value: UInt16, to output: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { output.append(contentsOf: $0) }
    }

    private static func readUInt16(_ bytes: Data, _ offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw EncryptedCallMediaError.invalidKey }
        let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return value
    }
}
