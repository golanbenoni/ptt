import Foundation
import PttWire
import Testing
@testable import PttTalkLib

@Test func productionVoicePipelineEncryptsAuthenticatesAndDecodesRepeatedFrames() throws {
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
        counterStore: MemorySFrameCounterStore()
    ) { packet in packets.append(packet) }
    let input = (0..<voiceSamplesPerFrame).map { index in
        Int16(sin(Double(index) * 2 * .pi * 997 / voiceSampleRate) * 24_000)
    }
    try outgoing.send(pcm: input)
    try outgoing.send(pcm: input)
    try outgoing.send(pcm: input)
    outgoing.close()

    let captured = packets.value
    #expect(captured.count == 4)
    #expect(captured.allSatisfy { $0.count == 160 })
    #expect(captured.allSatisfy { ProductionMediaDatagram.verifySenderAuthentication($0, demuxToken: token) })
    #expect(try ProductionMediaDatagram.decode(captured[0]).header.flags & productionMediaFlagStart != 0)
    #expect(try ProductionMediaDatagram.decode(captured[1]).header.flags == productionMediaFlagHmac8)
    #expect(try ProductionMediaDatagram.decode(captured[3]).header.flags & productionMediaFlagEnd != 0)

    let incoming = try IncomingVoiceStream(senderAci: UUID().uuidString, senderDeviceId: 1, announcement: announcement)
    #expect(incoming.matches(captured[0]))
    #expect(try incoming.accept(captured[0]))
    #expect(try incoming.accept(captured[2]))
    #expect(try incoming.accept(captured[3]))

    guard case let .frame(first, firstEnded, firstConcealed) = try incoming.pop() else {
        Issue.record("first frame did not leave the adaptive buffer")
        return
    }
    #expect(first.count == voiceSamplesPerFrame)
    #expect(!firstEnded && !firstConcealed)
    guard case let .frame(plc, plcEnded, plcConcealed) = try incoming.pop() else {
        Issue.record("missing packet did not invoke PLC")
        return
    }
    #expect(plc.count == voiceSamplesPerFrame)
    #expect(!plcEnded && plcConcealed)
    guard case let .frame(reordered, reorderedEnded, reorderedConcealed) = try incoming.pop() else {
        Issue.record("reordered packet was not played")
        return
    }
    #expect(reordered.count == voiceSamplesPerFrame)
    #expect(!reorderedEnded && !reorderedConcealed)
    guard case let .frame(end, ended, endConcealed) = try incoming.pop() else {
        Issue.record("end packet was not played")
        return
    }
    #expect(end.count == voiceSamplesPerFrame)
    #expect(ended && !endConcealed)
}

@Test func nativeJitterFlushesShortTransmissions() throws {
    let jitter = try NativeAdaptiveJitterBuffer()
    defer { jitter.close() }
    try jitter.push(sequence: 9, sentTimestampMs: 0, arrivalMs: 1, packet: Data([0, 42]))
    #expect(try jitter.pop() == .buffering)
    try jitter.flush()
    #expect(try jitter.pop() == .packet(Data([0, 42])))
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ packet: Data) { lock.withLock { packets.append(packet) } }
    var value: [Data] { lock.withLock { packets } }
}
