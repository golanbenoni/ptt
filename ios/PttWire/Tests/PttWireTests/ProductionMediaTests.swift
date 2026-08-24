import CryptoKit
import Foundation
import Testing
@testable import PttWire

@Test func productionDatagramRoundTripAndAuthentication() throws {
    let key = Data((0..<32).map(UInt8.init))
    let token = Data((32..<64).map(UInt8.init))
    let channel = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let talk = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    let plaintext = try ProductionVoicePayload.pack(opus: Data([0xf8, 0xff, 0xfe]))
    let encryptor = try SFrameEncryptor(kid: 9, baseKey: key, counters: MemorySFrameCounterStore())
    let aad = try productionSFrameAad(channelId: channel, talkId: talk, senderDemux: 0xfedcba98)
    let sframe = try encryptor.encrypt(metadata: aad, plaintext: plaintext)
    let header = try ProductionMediaHeader(
        flags: productionMediaFlagStart | productionMediaFlagHmac8,
        senderDemux: 0xfedcba98,
        sequence: UInt32.max,
        timestampRtp: 320,
        talkIdPrefix: productionTalkIdPrefix(talk)
    )
    let packet = try ProductionMediaDatagram.encode(header: header, sframe: sframe, demuxToken: token)

    #expect(packet.count == 160)
    #expect(ProductionMediaDatagram.verifySenderAuthentication(packet, demuxToken: token))
    let decoded = try ProductionMediaDatagram.decode(packet)
    #expect(decoded.header == header)
    #expect(decoded.sframe == sframe)

    let decryptor = SFrameDecryptor()
    try decryptor.addKey(kid: 9, baseKey: key)
    let opened = try decryptor.decrypt(metadata: aad, frame: decoded.sframe)
    #expect(try ProductionVoicePayload.unpack(opened) == Data([0xf8, 0xff, 0xfe]))
}

@Test func productionDatagramRejectsTamperingAndMalformedFields() throws {
    let key = Data(repeating: 7, count: 32)
    let token = Data(repeating: 8, count: 32)
    let talk = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    let encryptor = try SFrameEncryptor(kid: 1, baseKey: key, counters: MemorySFrameCounterStore())
    let aad = try productionSFrameAad(channelId: PttWire.channel, talkId: talk, senderDemux: 1)
    let sframe = try encryptor.encrypt(
        metadata: aad,
        plaintext: try ProductionVoicePayload.pack(opus: Data([1]))
    )
    let header = try ProductionMediaHeader(
        flags: productionMediaFlagHmac8,
        senderDemux: 1,
        sequence: 2,
        timestampRtp: 3,
        talkIdPrefix: productionTalkIdPrefix(talk)
    )
    var packet = try ProductionMediaDatagram.encode(header: header, sframe: sframe, demuxToken: token)
    packet[10] ^= 1
    #expect(!ProductionMediaDatagram.verifySenderAuthentication(packet, demuxToken: token))

    var wrongVersion = packet
    wrongVersion[0] = 2
    #expect(throws: ProductionMediaError.unsupportedVersion) {
        try ProductionMediaDatagram.decode(wrongVersion)
    }
    #expect(throws: ProductionMediaError.invalidDatagramLength) {
        try ProductionMediaDatagram.decode(Data(repeating: 0, count: 159))
    }
}

@Test func productionVoiceEnvelopeRequiresCanonicalPadding() throws {
    let packet = Data((1...98).map(UInt8.init))
    let packed = try ProductionVoicePayload.pack(opus: packet)
    #expect(packed.count == 99)
    #expect(try ProductionVoicePayload.unpack(packed) == packet)

    var nonCanonical = try ProductionVoicePayload.pack(opus: Data([1, 2]))
    nonCanonical[3] = 1
    #expect(throws: ProductionMediaError.nonCanonicalPadding) {
        try ProductionVoicePayload.unpack(nonCanonical)
    }
    #expect(throws: ProductionMediaError.invalidOpusPacket) {
        try ProductionVoicePayload.pack(opus: Data(repeating: 1, count: 99))
    }
}

@Test func productionAadIsExactFrozenLayout() throws {
    let channel = UUID(uuidString: "00112233-4455-4677-8899-aabbccddeeff")!
    let talk = UUID(uuidString: "ffeeddcc-bbaa-4988-8766-554433221100")!
    let aad = try productionSFrameAad(channelId: channel, talkId: talk, senderDemux: 0x01020304)
    #expect(aad.count == 36)
    #expect(aad.map { String(format: "%02x", $0) }.joined() ==
        "00112233445546778899aabbccddeeffffeeddccbbaa4988876655443322110001020304")
    #expect(productionTalkIdPrefix(talk) == Data([0xff, 0xee, 0xdd, 0xcc]))
}
