import CryptoKit
import Foundation
import Testing
@testable import PttWire

@Test func encryptedHistoryRoundTripsWithFrozenPrefix() throws {
    let channel = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let talk = UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!
    let key = Data((0..<32).map(UInt8.init))
    let packets = [Data((0..<160).map(UInt8.init)), Data((0..<160).map { UInt8(255 - $0) })]
    let blob = try EncryptedHistory.seal(
        channelId: channel,
        talkId: talk,
        membershipEpoch: 7,
        kid: 0x0102_0304_0506_0708,
        baseKey: key,
        packets: packets,
        nonce: Data((0..<12).map(UInt8.init))
    )
    #expect(blob.prefix(17).hex == "5054544801000102030405060708090a0b")
    #expect(Data(SHA256.hash(data: blob)).hex ==
        "f400a59caf393f5a249f83d6c384eac992948e4f036a716fcce6f194f55e5679")
    #expect(try EncryptedHistory.open(
        blob,
        channelId: channel,
        talkId: talk,
        membershipEpoch: 7,
        kid: 0x0102_0304_0506_0708,
        baseKey: key
    ) == packets)
}

@Test func encryptedHistoryRejectsTampering() throws {
    let channel = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let talk = UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!
    let key = Data(repeating: 4, count: 32)
    let packets = [Data(repeating: 9, count: 160)]
    var blob = try EncryptedHistory.seal(channelId: channel, talkId: talk, membershipEpoch: 1, kid: 2, baseKey: key, packets: packets, nonce: Data(repeating: 0, count: 12))
    blob[blob.index(before: blob.endIndex)] ^= 1
    #expect(throws: (any Error).self) {
        try EncryptedHistory.open(blob, channelId: channel, talkId: talk, membershipEpoch: 1, kid: 2, baseKey: key)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
