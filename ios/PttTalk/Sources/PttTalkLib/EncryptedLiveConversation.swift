import Foundation

public enum EncryptedLiveSignalKind: UInt8, Equatable, Sendable {
    case typingStarted = 1
    case typingStopped = 2
}

/// A short-lived value encrypted in the existing pairwise Signal envelope.
/// It is acknowledged from the mailbox but is never persisted as chat history.
public struct EncryptedLiveSignal: Equatable, Sendable {
    public let signalId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int32
    public let sentAt: Date
    public let expiresAt: Date
    public let kind: EncryptedLiveSignalKind
    public let threadRootId: UUID?

    public init(
        signalId: UUID,
        channelId: UUID,
        membershipEpoch: Int32,
        sentAt: Date,
        expiresAt: Date,
        kind: EncryptedLiveSignalKind,
        threadRootId: UUID? = nil
    ) {
        self.signalId = signalId
        self.channelId = channelId
        self.membershipEpoch = membershipEpoch
        self.sentAt = sentAt
        self.expiresAt = expiresAt
        self.kind = kind
        self.threadRootId = threadRootId
    }
}

public enum EncryptedLiveSignalCodec {
    private static let magic = Data("PTTI".utf8)
    private static let zeroUuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private static let wireBytes = 74
    public static let maximumTTL: TimeInterval = 30

    public static func encode(_ signal: EncryptedLiveSignal) throws -> Data {
        let ttl = signal.expiresAt.timeIntervalSince(signal.sentAt)
        guard signal.signalId != zeroUuid, signal.channelId != zeroUuid,
              signal.membershipEpoch > 0, ttl > 0, ttl <= maximumTTL else {
            throw EncryptedChatError.invalidEvent
        }
        var output = magic
        output.append(1)
        output.append(signal.kind.rawValue)
        output.append(contentsOf: uuidBytes(signal.signalId))
        output.append(contentsOf: uuidBytes(signal.channelId))
        append(signal.membershipEpoch, to: &output)
        append(Int64(signal.sentAt.timeIntervalSince1970 * 1_000), to: &output)
        append(Int64(signal.expiresAt.timeIntervalSince1970 * 1_000), to: &output)
        output.append(contentsOf: uuidBytes(signal.threadRootId ?? zeroUuid))
        guard output.count == wireBytes else { throw EncryptedChatError.invalidEvent }
        return output
    }

    public static func decode(_ bytes: Data) throws -> EncryptedLiveSignal {
        guard bytes.count == wireBytes, bytes.prefix(4) == magic, bytes[4] == 1,
              let kind = EncryptedLiveSignalKind(rawValue: bytes[5]) else {
            throw EncryptedChatError.invalidEvent
        }
        var offset = 6
        let signalId = try readUUID(bytes, &offset)
        let channelId = try readUUID(bytes, &offset)
        let epoch: Int32 = try read(bytes, &offset)
        let sentAtMs: Int64 = try read(bytes, &offset)
        let expiresAtMs: Int64 = try read(bytes, &offset)
        let root = try readUUID(bytes, &offset)
        let signal = EncryptedLiveSignal(
            signalId: signalId,
            channelId: channelId,
            membershipEpoch: epoch,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAtMs) / 1_000),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1_000),
            kind: kind,
            threadRootId: root == zeroUuid ? nil : root
        )
        guard try encode(signal) == bytes else { throw EncryptedChatError.invalidEvent }
        return signal
    }

    public static func isLiveSignal(_ bytes: Data) -> Bool {
        bytes.count >= magic.count && bytes.prefix(magic.count) == magic
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        withUnsafeBytes(of: value.uuid) { Array($0) }
    }

    private static func readUUID(_ data: Data, _ offset: inout Int) throws -> UUID {
        guard offset + 16 <= data.count else { throw EncryptedChatError.invalidEvent }
        let b = [UInt8](data[offset..<(offset + 16)])
        offset += 16
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, _ offset: inout Int) throws -> T {
        guard offset + MemoryLayout<T>.size <= data.count else { throw EncryptedChatError.invalidEvent }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size))
        }
        offset += MemoryLayout<T>.size
        return T(bigEndian: value)
    }
}
