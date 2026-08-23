import XCTest
@testable import PttWire

final class AadTests: XCTestCase {
    func testAadIs36Bytes() {
        let channel = UUID(uuidString: "01020304-0506-4708-890A-0B0C0D0E0F10")!
        let talk = UUID(uuidString: "11121314-1516-4718-991A-1B1C1D1E1F20")!
        let aad = PttWire.aad(channel: channel, talk: talk, demux: 0x01020304)
        XCTAssertEqual(aad.count, 36)
        XCTAssertEqual(hex(aad), Self.goldenAadHex)
    }

    func testBindPacketLayout() {
        let p = PttWire.bindPacket(channel: PttWire.channel, aci: PttWire.alice)
        XCTAssertEqual(p[p.startIndex], PttWire.bind)
        XCTAssertEqual(p.count, 33)
    }

    func testKeyPacketLayout() {
        let wrapped = Data([0xAA, 0xBB, 0xCC])
        let p = PttWire.keyPacket(
            channel: PttWire.channel,
            talk: PttWire.alice,
            demux: 1,
            frames: 40,
            wrappedKey: wrapped
        )
        XCTAssertEqual(PttWire.packetType(p), PttWire.key)
        XCTAssertEqual(PttWire.packetChannel(p), PttWire.channel)
        XCTAssertEqual(PttWire.packetTalkId(p), PttWire.alice)
        XCTAssertEqual(PttWire.packetDemux(p), 1)
        XCTAssertEqual(PttWire.packetKeyFrameCount(p), 40)
        XCTAssertEqual(PttWire.packetKeyWrapped(p), wrapped)
        XCTAssertEqual(p.count, 41 + wrapped.count)
    }

    func testAesGcmGoldenVectorMatchesKotlin() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let channel = UUID(uuidString: "01020304-0506-4708-890A-0B0C0D0E0F10")!
        let talk = UUID(uuidString: "11121314-1516-4718-991A-1B1C1D1E1F20")!
        let aad = PttWire.aad(channel: channel, talk: talk, demux: 0x01020304)
        let packet = try AesGcmFrames.encrypt(
            key: key,
            counter: 7,
            aad: aad,
            plaintext: Data("ptt-aes-gcm".utf8)
        )
        XCTAssertEqual(hex(packet), Self.goldenPacketHex)
        let plain = try AesGcmFrames.decrypt(key: key, aad: aad, packet: packet)
        XCTAssertEqual(plain, Data("ptt-aes-gcm".utf8))
    }

    private static let goldenAadHex =
        "0102030405064708890a0b0c0d0e0f10" +
        "1112131415164718991a1b1c1d1e1f20" +
        "01020304"

    /// Java AES/GCM/NoPadding + Python cryptography AESGCM, same nonce/AAD/key.
    private static let goldenPacketHex =
        "000000000000000739e75ddf0591cee0026974d93745ee74b750efef4655714edf3edc"

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
