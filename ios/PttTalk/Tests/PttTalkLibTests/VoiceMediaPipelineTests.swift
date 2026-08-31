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

@Test func closingBeforeMicrophoneAudioDoesNotCreateAnEmptyTransmission() throws {
    let packets = LockedPackets()
    let outgoing = try OutgoingVoiceStream(
        announcement: MediaEpochAnnouncement(
            channelId: UUID(),
            talkId: UUID(),
            membershipEpoch: 1,
            senderDemux: 0x1020_3040,
            kid: 8,
            baseKey: Data(repeating: 9, count: 32),
            totMs: 30_000
        ),
        demuxToken: Data(repeating: 7, count: 32),
        counterStore: MemorySFrameCounterStore()
    ) { packet in packets.append(packet) }

    outgoing.close()
    outgoing.close()

    #expect(packets.value.isEmpty)
}

@Test func productionVoicePipelineDeliversNonSilentAudioInsteadOfOnlyValidPackets() throws {
    let announcement = MediaEpochAnnouncement(
        channelId: UUID(),
        talkId: UUID(),
        membershipEpoch: 1,
        senderDemux: 0x1020_3040,
        kid: 10,
        baseKey: Data(repeating: 5, count: 32),
        totMs: 30_000
    )
    let token = Data(repeating: 11, count: 32)
    let packets = LockedPackets()
    let outgoing = try OutgoingVoiceStream(
        announcement: announcement,
        demuxToken: token,
        counterStore: MemorySFrameCounterStore()
    ) { packet in packets.append(packet) }

    // Keep phase continuous across frames. A packet-only test can pass while the
    // capture or codec path is carrying silence, which is useless to a listener.
    let frequency = 997.0
    for frameIndex in 0..<50 {
        let frame = (0..<voiceSamplesPerFrame).map { sampleIndex in
            let absoluteIndex = frameIndex * voiceSamplesPerFrame + sampleIndex
            return Int16(sin(Double(absoluteIndex) * 2 * .pi * frequency / voiceSampleRate) * 20_000)
        }
        try outgoing.send(pcm: frame)
    }
    outgoing.close()

    let incoming = try IncomingVoiceStream(
        senderAci: UUID().uuidString,
        senderDeviceId: 1,
        announcement: announcement
    )
    for packet in packets.value {
        #expect(try incoming.accept(packet))
    }

    var decoded: [Int16] = []
    var ended = false
    for _ in 0..<packets.value.count + 10 {
        switch try incoming.pop() {
        case .buffering:
            continue
        case let .frame(pcm, frameEnded, _):
            decoded.append(contentsOf: pcm)
            if frameEnded {
                ended = true
                break
            }
        }
    }

    let rms = sqrt(decoded.reduce(0.0) { partial, sample in
        partial + Double(sample) * Double(sample)
    } / Double(max(decoded.count, 1)))
    let audibleSamples = decoded.filter { abs(Int($0)) >= 1_000 }.count
    #expect(ended)
    #expect(decoded.count >= 50 * voiceSamplesPerFrame)
    #expect(rms > 5_000, "decoded RMS was \(rms); the media path delivered silence")
    #expect(audibleSamples > decoded.count / 2)
}

@Test func nativeJitterFlushesShortTransmissions() throws {
    let jitter = try NativeAdaptiveJitterBuffer()
    defer { jitter.close() }
    try jitter.push(sequence: 9, sentTimestampMs: 0, arrivalMs: 1, packet: Data([0, 42]))
    #expect(try jitter.pop() == .buffering)
    try jitter.flush()
    #expect(try jitter.pop() == .packet(Data([0, 42])))
}

@Test func incomingStreamExpiresWhenAnUnreliableEndMarkerIsLost() throws {
    let announcement = MediaEpochAnnouncement(
        channelId: UUID(),
        talkId: UUID(),
        membershipEpoch: 1,
        senderDemux: 0x5566_7788,
        kid: 11,
        baseKey: Data(repeating: 13, count: 32),
        totMs: 30_000
    )
    let packets = LockedPackets()
    let outgoing = try OutgoingVoiceStream(
        announcement: announcement,
        demuxToken: Data(repeating: 17, count: 32),
        counterStore: MemorySFrameCounterStore()
    ) { packet in packets.append(packet) }
    try outgoing.send(pcm: [Int16](repeating: 2_000, count: voiceSamplesPerFrame))

    let incoming = try IncomingVoiceStream(
        senderAci: UUID().uuidString,
        senderDeviceId: 1,
        announcement: announcement
    )
    #expect(try incoming.accept(packets.value[0]))
    let acceptedAt = try #require(incoming.lastMediaAtMs)
    #expect(!incoming.isInactive(nowMs: acceptedAt + 749))
    #expect(incoming.isInactive(nowMs: acceptedAt + 750))
}

@Test func releasingWhileSecuritySetupIsInFlightInvalidatesThatTransmitAttempt() {
    var attempts = VoiceTransmitAttemptGate()
    let first = attempts.begin()
    #expect(attempts.isCurrent(first))

    attempts.cancel()
    #expect(!attempts.isCurrent(first))

    let retry = attempts.begin()
    #expect(attempts.isCurrent(retry))
    #expect(!attempts.isCurrent(first))
}

@Test func floorRequestRefreshesOnlyAfterTheServerReportsAStaleMembershipEpoch() {
    #expect(!FloorRequestMetadataPolicy.requiresRefresh(status: nil, code: nil))
    #expect(!FloorRequestMetadataPolicy.requiresRefresh(status: 409, code: "FLOOR_BUSY"))
    #expect(FloorRequestMetadataPolicy.requiresRefresh(status: 409, code: "STALE_MEMBERSHIP_EPOCH"))
    #expect(FloorRequestMetadataPolicy.requiresRefresh(status: 409, code: "MEMBERSHIP_EPOCH_MISMATCH"))
}

@Test func unknownMediaCoalescesExpeditedMailboxLookups() {
    var gate = VoiceMailboxWakeGate()
    let initial = gate.begin()
    let coalesced = gate.begin()
    let rerun = gate.finish()
    let completed = gate.finish()
    let next = gate.begin()
    #expect(initial)
    #expect(!coalesced)
    #expect(rerun)
    #expect(!completed)
    #expect(next)
}

@Test func repeatedHoldGestureDoesNotReplaceTheActiveChannelWithAFalseError() {
    let channelId = UUID()
    #expect(HoldToTalkInteractionPolicy.startDecision(
        transmitRequested: false,
        activeChannelId: channelId
    ) == .begin(channelId))
    #expect(HoldToTalkInteractionPolicy.startDecision(
        transmitRequested: true,
        activeChannelId: channelId
    ) == .ignoreRepeatedPress)
    #expect(HoldToTalkInteractionPolicy.startDecision(
        transmitRequested: false,
        activeChannelId: nil
    ) == .channelUnavailable)
}

@Test func releasingWhileMicrophonePermissionIsPendingCannotRestartTransmission() {
    #expect(HoldToTalkInteractionPolicy.shouldContinueAfterPermission(
        transmitRequested: true,
        microphoneAllowed: true
    ))
    #expect(!HoldToTalkInteractionPolicy.shouldContinueAfterPermission(
        transmitRequested: false,
        microphoneAllowed: true
    ))
    #expect(!HoldToTalkInteractionPolicy.shouldContinueAfterPermission(
        transmitRequested: true,
        microphoneAllowed: false
    ))
}

@Test func systemManagedPlaybackWaitsForAudioSessionActivation() {
    #expect(!VoiceAudioActivationGate.canUseAudio(
        requiresExternalActivation: true,
        externalAudioActive: false
    ))
    #expect(VoiceAudioActivationGate.canUseAudio(
        requiresExternalActivation: true,
        externalAudioActive: true
    ))
    #expect(VoiceAudioActivationGate.canUseAudio(
        requiresExternalActivation: false,
        externalAudioActive: false
    ))
}

@Test func microphoneStartupPrefersTheHardwareInputFormat() {
    #expect(VoiceAudioInputFormatPolicy.preferredSource(
        hardwareInputSampleRate: 48_000,
        hardwareInputChannels: 1,
        nodeOutputSampleRate: 0,
        nodeOutputChannels: 0
    ) == .hardwareInput)
}

@Test func microphoneStartupFallsBackOnlyToAUsableNodeOutputFormat() {
    #expect(VoiceAudioInputFormatPolicy.preferredSource(
        hardwareInputSampleRate: 0,
        hardwareInputChannels: 0,
        nodeOutputSampleRate: 48_000,
        nodeOutputChannels: 1
    ) == .nodeOutput)
    #expect(VoiceAudioInputFormatPolicy.preferredSource(
        hardwareInputSampleRate: 0,
        hardwareInputChannels: 0,
        nodeOutputSampleRate: 0,
        nodeOutputChannels: 0
    ) == nil)
    #expect(VoiceAudioInputFormatPolicy.preferredSource(
        hardwareInputSampleRate: .nan,
        hardwareInputChannels: 1,
        nodeOutputSampleRate: 0,
        nodeOutputChannels: 1
    ) == nil)
}

@Test func systemManagedAudioIsConfiguredBeforeActivationAndNotDuringCapture() {
    #expect(VoiceAudioSessionManagementPolicy.configureBeforeSystemActivation(
        systemManagesAudioSession: true
    ))
    #expect(!VoiceAudioSessionManagementPolicy.configureWhenCaptureStarts(
        systemManagesAudioSession: true
    ))
    #expect(!VoiceAudioSessionManagementPolicy.configureBeforeSystemActivation(
        systemManagesAudioSession: false
    ))
    #expect(VoiceAudioSessionManagementPolicy.configureWhenCaptureStarts(
        systemManagesAudioSession: false
    ))
    #expect(!VoiceAudioSessionManagementPolicy.rebuildGraphWhenCaptureStarts(
        systemManagesAudioSession: true
    ))
    #expect(VoiceAudioSessionManagementPolicy.rebuildGraphWhenCaptureStarts(
        systemManagesAudioSession: false
    ))
}

@Test func microphoneRouteRecoveryAllowsAFullTwoSecondHardwareWindow() {
    #expect(VoiceAudioInputFormatPolicy.engineStateAttempts == 2)
    #expect(VoiceAudioInputFormatPolicy.maximumRouteSettleMs >= 2_000)
}

@Test func captureReleaseIgnoresOnlyExpectedClosedStreamErrors() {
    #expect(!VoiceCaptureSendFailurePolicy.shouldReport(VoiceMediaError.closed))
    #expect(!VoiceCaptureSendFailurePolicy.shouldReport(TlsMediaRelayError.closed))
    #expect(VoiceCaptureSendFailurePolicy.shouldReport(
        NSError(domain: "VoiceCaptureRegression", code: 1)
    ))
}

@Test func playoutMaintainsAThreeFrameLeadWithoutOverfilling() {
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: -1) == 3)
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: 0) == 3)
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: 1) == 2)
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: 2) == 1)
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: 3) == 0)
    #expect(VoicePlayoutQueuePolicy.framesToSchedule(currentQueued: 8) == 0)
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func append(_ packet: Data) { lock.withLock { packets.append(packet) } }
    var value: [Data] { lock.withLock { packets } }
}
