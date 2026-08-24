import Foundation
import PttWire
import Testing
@testable import PttTalkLib

@Test func productionVoicePipelineEncryptsAuthenticatesAndDecodesRepeatedFrames() throws {
    let namespace = "app.ptt.talk.tests.media.\(UUID().uuidString)"
    let store = try KeychainSignalProtocolStore(namespace: namespace)
    defer { try? store.deleteAllForTesting() }
    let announcement = MediaEpochAnnouncement(
        channelId: UUID(),
        talkId: UUID(),
        membershipEpoch: 1,
        senderDemux: 0xfedcba98,
        kid: 9,
        baseKey: Data(repeating: 3, count: 32),
        totMs: 30_000
    )
    let token = Data(repeating: 7, count: 32)
    let packets = LockedPackets()
    let outgoing = try OutgoingVoiceStream(
        announcement: announcement,
        demuxToken: token,
        signalStore: store,
        counterStream: "test/channel/device"
    ) { packet in packets.append(packet) }
    let input = (0..<voiceSamplesPerFrame).map { index in
        Int16(sin(Double(index) * 2 * .pi * 997 / voiceSampleRate) * 24_000)
    }
    try outgoing.send(pcm: input)
    try outgoing.send(pcm: input)
    outgoing.close()

    let captured = packets.value
    #expect(captured.count == 3)
    #expect(captured.allSatisfy { $0.count == 160 })
    #expect(captured.allSatisfy { ProductionMediaDatagram.verifySenderAuthentication($0, demuxToken: token) })
    #expect(try ProductionMediaDatagram.decode(captured[0]).header.flags & productionMediaFlagStart != 0)
    #expect(try ProductionMediaDatagram.decode(captured[1]).header.flags == productionMediaFlagHmac8)
    #expect(try ProductionMediaDatagram.decode(captured[2]).header.flags & productionMediaFlagEnd != 0)

    let incoming = try IncomingVoiceStream(senderAci: UUID().uuidString, senderDeviceId: 1, announcement: announcement)
    #expect(incoming.matches(captured[0]))
    #expect(try incoming.accept(captured[0])?.count == voiceSamplesPerFrame)
    #expect(try incoming.accept(captured[1])?.count == voiceSamplesPerFrame)
    #expect(try incoming.accept(captured[2])?.count == voiceSamplesPerFrame)
    #expect(try incoming.concealLoss().count == voiceSamplesPerFrame)
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ packet: Data) { lock.withLock { packets.append(packet) } }
    var value: [Data] { lock.withLock { packets } }
}
