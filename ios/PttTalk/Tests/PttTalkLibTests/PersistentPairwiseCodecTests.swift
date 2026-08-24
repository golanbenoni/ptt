import Foundation
import LibSignalClient
import Testing
@testable import PttTalkLib

@Test func prekeyPublicationStateIsScopedToServerAccountAndDevice() {
    let first = PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
        serverUrl: "https://ptt.example.test/",
        aci: "00112233-4455-4677-8899-AABBCCDDEEFF",
        deviceId: 1
    )
    #expect(first == PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
        serverUrl: "https://ptt.example.test",
        aci: "00112233-4455-4677-8899-aabbccddeeff",
        deviceId: 1
    ))
    #expect(first.count == 61)
    #expect(first.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    #expect(first != PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
        serverUrl: "https://other.example.test",
        aci: "00112233-4455-4677-8899-aabbccddeeff",
        deviceId: 1
    ))
    #expect(first != PersistentPairwiseCrypto.prekeyPublishedAtStateKey(
        serverUrl: "https://ptt.example.test",
        aci: "00112233-4455-4677-8899-aabbccddeeff",
        deviceId: 2
    ))
}

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

@Test func senderKeyEnvelopeMatchesFrozenAndroidLayout() throws {
    let aci = "00112233-4455-4677-8899-aabbccddeeff"
    let distribution = UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    let keyEnvelope = Data([0x50, 0x54, 0x54, 0x45, 1, 2, 3])
    let ciphertext = Data([9, 8, 7, 6])
    let encoded = try PersistentPairwiseCrypto.encodeGroupEnvelope(
        senderAci: aci,
        senderDeviceId: 2,
        distributionId: distribution,
        keyEnvelope: keyEnvelope,
        ciphertext: ciphertext
    )
    #expect(encoded.prefix(5) == Data([0x50, 0x54, 0x54, 0x47, 1]))
    #expect(encoded[21] == 2)
    #expect(encoded[22..<38] == Data([
        0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x47, 0x87,
        0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f,
    ]))
    #expect(encoded[38..<42] == Data([0, 0, 0, 7]))
    let decoded = try PersistentPairwiseCrypto.decodeGroupEnvelope(encoded)
    #expect(decoded.senderAci == aci)
    #expect(decoded.senderDeviceId == 2)
    #expect(decoded.distributionId == distribution)
    #expect(decoded.keyEnvelope == keyEnvelope)
    #expect(decoded.ciphertext == ciphertext)
}

@Test func senderKeyDistributionMatchesFrozenAndroidLayout() throws {
    let distribution = UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    let encoded = try PersistentPairwiseCrypto.encodeSenderKeyDistribution(
        distributionId: distribution,
        message: Data([1, 3, 5])
    )
    #expect(encoded.prefix(5) == Data([0x50, 0x54, 0x54, 0x4b, 1]))
    #expect(encoded[21..<25] == Data([0, 0, 0, 3]))
    let decoded = try PersistentPairwiseCrypto.decodeSenderKeyDistribution(encoded)
    #expect(decoded.distributionId == distribution)
    #expect(decoded.message == Data([1, 3, 5]))
}

@Test func authenticatedSenderKeyRoundTripRejectsUnknownAndAlteredCiphertext() throws {
    let sender = try ProtocolAddress(name: "00112233-4455-4677-8899-aabbccddeeff", deviceId: 1)
    let distribution = UUID(uuidString: "10213243-5465-4787-98a9-bacbdcedfe0f")!
    let context = NullContext()
    let senderStore = InMemorySignalProtocolStore()
    let receiverStore = InMemorySignalProtocolStore()
    let unknownStore = InMemorySignalProtocolStore()
    let distributionMessage = try SenderKeyDistributionMessage(
        from: sender,
        distributionId: distribution,
        store: senderStore,
        context: context
    )
    try processSenderKeyDistributionMessage(
        SenderKeyDistributionMessage(bytes: distributionMessage.serialize()),
        from: sender,
        store: receiverStore,
        context: context
    )
    let plaintext = Data("authenticated media epoch".utf8)
    let ciphertext = try groupEncrypt(
        plaintext,
        from: sender,
        distributionId: distribution,
        store: senderStore,
        context: context
    ).serialize()
    #expect(try groupDecrypt(ciphertext, from: sender, store: receiverStore, context: context) == plaintext)
    #expect(throws: (any Error).self) {
        try groupDecrypt(ciphertext, from: sender, store: unknownStore, context: context)
    }
    var altered = ciphertext
    altered[altered.count - 1] ^= 1
    #expect(throws: (any Error).self) {
        try groupDecrypt(altered, from: sender, store: receiverStore, context: context)
    }
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
