import Foundation

/// Byte-for-byte match of `docs/WIRE.md` / `app.ptt.net.Packets`.
/// Crypto (PQXDH, sender keys) uses LibSignalClient on a Mac; this module is the wire.
public enum PttWire {
    public static let bind: UInt8 = 0xB1
    public static let key: UInt8 = 0x4B
    public static let frame: UInt8 = 0xF1

    public static let alice = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    public static let bob = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    public static let channel = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!

    public static func uuidBytes(_ u: UUID) -> [UInt8] {
        let t = u.uuid
        return [
            t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
        ]
    }

    public static func uuidAt(_ data: Data, _ offset: Int) -> UUID {
        let b = [UInt8](data[offset..<(offset + 16)])
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    public static func u32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data[offset..<(offset + 4)])
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    public static func appendU32BE(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    public static func bindPacket(channel: UUID, aci: UUID) -> Data {
        var d = Data([bind])
        d.append(contentsOf: uuidBytes(channel))
        d.append(contentsOf: uuidBytes(aci))
        return d
    }

    /// `0x4B` || channel || talk || demux u32 BE || frame_count u32 BE || PQXDH-wrapped key.
    public static func keyPacket(
        channel: UUID,
        talk: UUID,
        demux: UInt32,
        frames: UInt32,
        wrappedKey: Data
    ) -> Data {
        var d = Data([key])
        d.append(contentsOf: uuidBytes(channel))
        d.append(contentsOf: uuidBytes(talk))
        appendU32BE(&d, demux)
        appendU32BE(&d, frames)
        d.append(wrappedKey)
        return d
    }

    /// `0xF1` || channel || talk || demux u32 BE || AES-GCM packet.
    public static func framePacket(channel: UUID, talk: UUID, demux: UInt32, payload: Data) -> Data {
        var d = Data([frame])
        d.append(contentsOf: uuidBytes(channel))
        d.append(contentsOf: uuidBytes(talk))
        appendU32BE(&d, demux)
        d.append(payload)
        return d
    }

    public static func packetType(_ p: Data) -> UInt8 { p[p.startIndex] }
    public static func packetChannel(_ p: Data) -> UUID { uuidAt(p, 1) }
    public static func packetTalkId(_ p: Data) -> UUID { uuidAt(p, 17) }
    public static func packetDemux(_ p: Data) -> UInt32 { u32BE(p, 33) }
    public static func packetKeyFrameCount(_ p: Data) -> UInt32 { u32BE(p, 37) }
    public static func packetKeyWrapped(_ p: Data) -> Data { p.subdata(in: (p.startIndex + 41)..<p.endIndex) }
    public static func packetFramePayload(_ p: Data) -> Data { p.subdata(in: (p.startIndex + 37)..<p.endIndex) }

    /// AES-GCM AAD: channel(16) || talk(16) || demux u32 BE.
    public static func aad(channel: UUID, talk: UUID, demux: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: uuidBytes(channel))
        d.append(contentsOf: uuidBytes(talk))
        appendU32BE(&d, demux)
        return d
    }
}
