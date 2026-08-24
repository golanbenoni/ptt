import CryptoKit
import Foundation

public let productionMediaDatagramBytes = 160
public let productionMediaHeaderBytes = 20
public let productionMediaHmacBytes = 8
public let productionMediaSFrameCapacity =
    productionMediaDatagramBytes - productionMediaHeaderBytes - productionMediaHmacBytes
public let productionVoicePlaintextBytes = 99
public let productionMaxOpusPacketBytes = productionVoicePlaintextBytes - 1

public let productionMediaFlagFec: UInt8 = 0x01
public let productionMediaFlagStart: UInt8 = 0x02
public let productionMediaFlagEnd: UInt8 = 0x04
public let productionMediaFlagHmac8: UInt8 = 0x08

public struct ProductionMediaHeader: Equatable, Sendable {
    public let flags: UInt8
    public let senderDemux: UInt32
    public let sequence: UInt32
    public let timestampRtp: UInt32
    public let talkIdPrefix: Data

    public init(
        flags: UInt8,
        senderDemux: UInt32,
        sequence: UInt32,
        timestampRtp: UInt32,
        talkIdPrefix: Data
    ) throws {
        guard flags & productionMediaFlagHmac8 != 0 else {
            throw ProductionMediaError.missingAuthenticationFlag
        }
        guard flags & 0xf0 == 0 else { throw ProductionMediaError.unknownFlags }
        guard senderDemux != 0 else { throw ProductionMediaError.invalidDemux }
        guard talkIdPrefix.count == 4 else { throw ProductionMediaError.invalidTalkIdPrefix }
        self.flags = flags
        self.senderDemux = senderDemux
        self.sequence = sequence
        self.timestampRtp = timestampRtp
        self.talkIdPrefix = talkIdPrefix
    }
}

public struct ReceivedProductionMedia: Equatable, Sendable {
    public let header: ProductionMediaHeader
    public let sframe: Data
}

public enum ProductionMediaDatagram {
    public static func encode(
        header: ProductionMediaHeader,
        sframe: Data,
        demuxToken: Data
    ) throws -> Data {
        guard demuxToken.count == 32 else { throw ProductionMediaError.invalidDemuxToken }
        let actualLength = try SFrame.frameLength(sframe, plaintextLength: productionVoicePlaintextBytes)
        guard actualLength == sframe.count, sframe.count <= productionMediaSFrameCapacity else {
            throw ProductionMediaError.invalidSFrame
        }

        var output = Data(capacity: productionMediaDatagramBytes)
        output.append(1)
        output.append(header.flags)
        appendBigEndian(header.senderDemux, to: &output)
        appendBigEndian(header.sequence, to: &output)
        appendBigEndian(header.timestampRtp, to: &output)
        output.append(contentsOf: [0, 0])
        output.append(header.talkIdPrefix)
        output.append(sframe)
        output.append(Data(repeating: 0, count: productionMediaDatagramBytes - productionMediaHmacBytes - output.count))
        output.append(hmac8(key: demuxToken, message: output))
        guard output.count == productionMediaDatagramBytes else {
            throw ProductionMediaError.invalidDatagramLength
        }
        return output
    }

    /// Parses relay-forwarded media. The relay already checked the sender HMAC;
    /// receivers authenticate all routing fields again as SFrame metadata.
    public static func decode(_ packet: Data) throws -> ReceivedProductionMedia {
        guard packet.count == productionMediaDatagramBytes else {
            throw ProductionMediaError.invalidDatagramLength
        }
        guard packet[packet.startIndex] == 1 else { throw ProductionMediaError.unsupportedVersion }
        let flags = packet[packet.startIndex + 1]
        guard readUInt16(packet, at: 14) == 0 else { throw ProductionMediaError.unsupportedPayloadType }
        let header = try ProductionMediaHeader(
            flags: flags,
            senderDemux: readUInt32(packet, at: 2),
            sequence: readUInt32(packet, at: 6),
            timestampRtp: readUInt32(packet, at: 10),
            talkIdPrefix: packet.subdata(in: 16..<20)
        )
        let padded = packet.subdata(in: productionMediaHeaderBytes..<(packet.count - productionMediaHmacBytes))
        let length = try SFrame.frameLength(padded, plaintextLength: productionVoicePlaintextBytes)
        guard length <= padded.count else { throw ProductionMediaError.invalidSFrame }
        return ReceivedProductionMedia(header: header, sframe: padded.prefix(length))
    }

    public static func verifySenderAuthentication(_ packet: Data, demuxToken: Data) -> Bool {
        guard packet.count == productionMediaDatagramBytes, demuxToken.count == 32 else { return false }
        let authenticated = packet.prefix(packet.count - productionMediaHmacBytes)
        let expected = hmac8(key: demuxToken, message: authenticated)
        return constantTimeEqual(expected, packet.suffix(productionMediaHmacBytes))
    }
}

public enum ProductionVoicePayload {
    public static func pack(opus: Data) throws -> Data {
        guard !opus.isEmpty, opus.count <= productionMaxOpusPacketBytes else {
            throw ProductionMediaError.invalidOpusPacket
        }
        var output = Data([UInt8(opus.count)])
        output.append(opus)
        output.append(Data(repeating: 0, count: productionVoicePlaintextBytes - output.count))
        return output
    }

    public static func unpack(_ plaintext: Data) throws -> Data {
        guard plaintext.count == productionVoicePlaintextBytes,
              let length = plaintext.first.map(Int.init),
              (1...productionMaxOpusPacketBytes).contains(length)
        else { throw ProductionMediaError.invalidOpusPacket }
        guard plaintext[(1 + length)...].allSatisfy({ $0 == 0 }) else {
            throw ProductionMediaError.nonCanonicalPadding
        }
        return plaintext.subdata(in: 1..<(1 + length))
    }
}

public func productionSFrameAad(channelId: UUID, talkId: UUID, senderDemux: UInt32) throws -> Data {
    guard senderDemux != 0 else { throw ProductionMediaError.invalidDemux }
    var output = Data(PttWire.uuidBytes(channelId))
    output.append(contentsOf: PttWire.uuidBytes(talkId))
    appendBigEndian(senderDemux, to: &output)
    return output
}

public func productionTalkIdPrefix(_ talkId: UUID) -> Data {
    Data(PttWire.uuidBytes(talkId).prefix(4))
}

public enum ProductionMediaError: Error, Equatable {
    case invalidDatagramLength
    case unsupportedVersion
    case missingAuthenticationFlag
    case unknownFlags
    case invalidDemux
    case invalidTalkIdPrefix
    case invalidDemuxToken
    case unsupportedPayloadType
    case invalidSFrame
    case invalidOpusPacket
    case nonCanonicalPadding
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    data.append(Data(bytes: &bigEndian, count: MemoryLayout<T>.size))
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
}

private func hmac8(key: Data, message: some DataProtocol) -> Data {
    let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
    return Data(digest.prefix(productionMediaHmacBytes))
}

private func constantTimeEqual(_ lhs: Data, _ rhs: some DataProtocol) -> Bool {
    let right = Data(rhs)
    guard lhs.count == right.count else { return false }
    return zip(lhs, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
