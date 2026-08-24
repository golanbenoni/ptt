import Foundation
import Testing
@testable import PttTalkLib

@Test func mediaAnnouncementMatchesFrozenAndroidLayout() throws {
    let value = MediaEpochAnnouncement(
        channelId: UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!,
        talkId: UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!,
        membershipEpoch: 7,
        senderDemux: 0xfedcba98,
        kid: 0x0102030405060708,
        baseKey: Data(0..<32),
        totMs: 30_000,
        isSos: true
    )
    let encoded = try PersistentPairwiseCrypto.encodeAnnouncement(value)
    #expect(encoded.count == 90)
    #expect(encoded.prefix(6) == Data([0x50, 0x54, 0x54, 0x4d, 2, 1]))
    #expect(encoded[38..<42] == Data([0, 0, 0, 7]))
    #expect(encoded[42..<46] == Data([0xfe, 0xdc, 0xba, 0x98]))
    #expect(encoded[46..<54] == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    #expect(try PersistentPairwiseCrypto.decodeAnnouncement(encoded) == value)
}

@Test func pairwiseOuterEnvelopeMatchesFrozenAndroidLayout() throws {
    let aci = "00112233-4455-4677-8899-aabbccddeeff"
    let encoded = try PersistentPairwiseCrypto.encodeOuterEnvelope(
        senderAci: aci,
        senderDeviceId: 2,
        ciphertext: Data([9, 8, 7])
    )
    #expect(encoded == Data([
        0x50, 0x54, 0x54, 0x45, 1,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        2, 9, 8, 7,
    ]))
    let decoded = try PersistentPairwiseCrypto.decodeOuterEnvelope(encoded)
    #expect(decoded.senderAci == aci)
    #expect(decoded.senderDeviceId == 2)
    #expect(decoded.ciphertext == Data([9, 8, 7]))
}

@Test func mediaAnnouncementRejectsInvalidSecurityBounds() {
    let invalid = MediaEpochAnnouncement(
        channelId: UUID(), talkId: UUID(), membershipEpoch: 0, senderDemux: 0,
        kid: 0, baseKey: Data(repeating: 1, count: 31), totMs: 60_001
    )
    #expect(throws: PersistentCryptoError.invalidAnnouncement) {
        try PersistentPairwiseCrypto.encodeAnnouncement(invalid)
    }
}
