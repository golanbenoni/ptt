import Foundation
import LibSignalClient
import OSLog
import PttWire

private let voiceLatencyLogger = Logger(subsystem: "app.ptt.talk", category: "voice-latency")

private final class HistoryPacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) {
        lock.withLock {
            if packets.count < 1_501 { packets.append(packet) }
        }
    }

    func snapshot() -> [Data] { lock.withLock { packets } }
}

struct VoiceTransmitAttemptGate: Sendable {
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func cancel() { generation &+= 1 }

    func isCurrent(_ attempt: UInt64) -> Bool { attempt == generation }
}

struct VoiceAudioActivationGate: Sendable {
    static func canUseAudio(requiresExternalActivation: Bool, externalAudioActive: Bool) -> Bool {
        !requiresExternalActivation || externalAudioActive
    }
}

public struct FloorRequestMetadataPolicy: Sendable {
    public static func requiresRefresh(status: Int?, code: String?) -> Bool {
        guard status == 409 else { return false }
        return code == "STALE_MEMBERSHIP_EPOCH" || code == "MEMBERSHIP_EPOCH_MISMATCH"
    }
}

struct VoiceMailboxWakeGate: Sendable {
    private var polling = false
    private var rerunRequested = false

    mutating func begin() -> Bool {
        guard !polling else {
            rerunRequested = true
            return false
        }
        polling = true
        return true
    }

    mutating func finish() -> Bool {
        if rerunRequested {
            rerunRequested = false
            return true
        }
        polling = false
        return false
    }
}

public enum VoiceAudioInputFormatSource: Equatable, Sendable {
    case hardwareInput
    case nodeOutput
}

public struct VoiceAudioInputFormatPolicy: Sendable {
    public static let routeSettleAttemptsPerEngineState = 25
    public static let routeSettleDelayMs = 40
    public static let engineStateAttempts = 2

    public static var maximumRouteSettleMs: Int {
        routeSettleAttemptsPerEngineState * routeSettleDelayMs * engineStateAttempts
    }

    public static func preferredSource(
        hardwareInputSampleRate: Double,
        hardwareInputChannels: UInt32,
        nodeOutputSampleRate: Double,
        nodeOutputChannels: UInt32
    ) -> VoiceAudioInputFormatSource? {
        if isUsable(sampleRate: hardwareInputSampleRate, channels: hardwareInputChannels) {
            return .hardwareInput
        }
        if isUsable(sampleRate: nodeOutputSampleRate, channels: nodeOutputChannels) {
            return .nodeOutput
        }
        return nil
    }

    private static func isUsable(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channels > 0
    }
}

public struct VoiceAudioSessionManagementPolicy: Sendable {
    public static func configureBeforeSystemActivation(systemManagesAudioSession: Bool) -> Bool {
        systemManagesAudioSession
    }

    public static func configureWhenCaptureStarts(systemManagesAudioSession: Bool) -> Bool {
        !systemManagesAudioSession
    }

    public static func rebuildGraphWhenCaptureStarts(systemManagesAudioSession: Bool) -> Bool {
        !systemManagesAudioSession
    }
}

public enum VoiceCaptureSendFailurePolicy {
    public static func shouldReport(_ error: Error) -> Bool {
        if case VoiceMediaError.closed = error { return false }
        if case TlsMediaRelayError.closed = error { return false }
        return true
    }
}

public protocol VoiceAudioIO: AnyObject, Sendable {
    func preparePlayback() throws
    func prepareCapture() throws
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws
    func stopCapture()
    func play(_ pcm: [Int16]) throws
    func queuedPlaybackFrameCount() -> Int
}

public extension VoiceAudioIO {
    func preparePlayback() throws {}
    func prepareCapture() throws {}
}

struct VoicePlayoutQueuePolicy: Sendable {
    static let targetFrames = 3

    static func framesToSchedule(currentQueued: Int) -> Int {
        max(0, targetFrames - max(0, currentQueued))
    }
}

public enum HoldToTalkStartDecision: Equatable, Sendable {
    case begin(UUID)
    case ignoreRepeatedPress
    case channelUnavailable
}

public struct HoldToTalkInteractionPolicy: Sendable {
    public static func startDecision(
        transmitRequested: Bool,
        activeChannelId: UUID?
    ) -> HoldToTalkStartDecision {
        if transmitRequested { return .ignoreRepeatedPress }
        guard let activeChannelId else { return .channelUnavailable }
        return .begin(activeChannelId)
    }

    public static func shouldContinueAfterPermission(
        transmitRequested: Bool,
        microphoneAllowed: Bool
    ) -> Bool {
        transmitRequested && microphoneAllowed
    }
}

public struct VoiceEncryptionDetails: Equatable, Sendable {
    public let algorithm: String
    public let keyEstablishment: String
    public let channelId: UUID
    public let talkId: UUID
    public let senderDemux: UInt32
    public let kid: UInt64
    public let membershipEpoch: Int
    public let senderAci: String
    public let senderDeviceId: Int
    public let isSos: Bool

    public init(
        algorithm: String,
        keyEstablishment: String,
        channelId: UUID,
        talkId: UUID,
        senderDemux: UInt32,
        kid: UInt64,
        membershipEpoch: Int,
        senderAci: String,
        senderDeviceId: Int,
        isSos: Bool
    ) {
        self.algorithm = algorithm
        self.keyEstablishment = keyEstablishment
        self.channelId = channelId
        self.talkId = talkId
        self.senderDemux = senderDemux
        self.kid = kid
        self.membershipEpoch = membershipEpoch
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.isSos = isSos
    }
}

public struct VoiceHistoryItem: Equatable, Identifiable, Sendable {
    public let talkId: UUID
    public let channelId: UUID
    public let senderAci: String
    public let senderDeviceId: Int
    public let startedAt: Date
    public let durationMs: Int
    public let expiresAt: Date
    public let isSos: Bool
    public var id: UUID { talkId }

    public init(
        talkId: UUID,
        channelId: UUID,
        senderAci: String,
        senderDeviceId: Int,
        startedAt: Date,
        durationMs: Int,
        expiresAt: Date,
        isSos: Bool
    ) {
        self.talkId = talkId
        self.channelId = channelId
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.expiresAt = expiresAt
        self.isSos = isSos
    }
}

public enum VoiceSessionEvent: Equatable, Sendable {
    case preparing(String)
    case relayState(MediaRelayConnectionState)
    case ready(String)
    case requestingFloor
    case floorGranted(latencyMs: UInt64)
    case floorDenied(String)
    case transmitting(VoiceEncryptionDetails, readyLatencyMs: UInt64)
    case receiving(VoiceEncryptionDetails)
    case historyUpdated
    case deviceRevoked
    case error(String)
}

public actor ProductionVoiceSession {
    private struct PendingPacket {
        let receivedAt: Date
        let data: Data
    }

    private let session: DeviceSession
    private let api: ControlApi
    private let store: KeychainSignalProtocolStore
    private let crypto: PersistentPairwiseCrypto
    private let historyArchive: SecureVoiceHistoryArchive
    private let audio: VoiceAudioIO
    private let requiresExternalAudioActivation: Bool
    private let onEvent: @Sendable (VoiceSessionEvent) -> Void
    private var channel: ChannelSummary?
    private var credential: RelayCredential?
    private var relay: MediaRelay?
    private var outgoing: OutgoingVoiceStream?
    private var outgoingAnnouncement: MediaEpochAnnouncement?
    private var outgoingStartedAt: Date?
    private var historyCollector: HistoryPacketCollector?
    private var floorToken: String?
    private var incoming: [UUID: IncomingVoiceStream] = [:]
    private var receivingTalkIds: Set<UUID> = []
    private var pendingPackets: [PendingPacket] = []
    private var mailboxTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?
    private var floorTimeoutTask: Task<Void, Never>?
    private var relayRefreshTask: Task<Void, Never>?
    private var historySyncTask: Task<Void, Never>?
    private var historyPlaybackTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var relayRefreshing = false
    private var relayAvailable = false
    private var lastChannelMetadataRefresh = Date.distantPast
    private var cachedChannelDevices: [ChannelDevice] = []
    private var cachedDevicesChannelId: String?
    private var cachedDevicesMembershipEpoch: Int?
    private var externalAudioActive = false
    private var captureStarted = false
    private var revoked = false
    private var presenceMode = "available"
    private var transmitAttempts = VoiceTransmitAttemptGate()
    private var mailboxWakeGate = VoiceMailboxWakeGate()
    private var endingTransmit = false

    public init(
        session: DeviceSession,
        signalStore: KeychainSignalProtocolStore,
        pairwiseCrypto: PersistentPairwiseCrypto? = nil,
        audio: VoiceAudioIO,
        allowInsecureHttp: Bool = false,
        requiresExternalAudioActivation: Bool = false,
        onEvent: @escaping @Sendable (VoiceSessionEvent) -> Void
    ) throws {
        self.session = session
        self.store = signalStore
        self.audio = audio
        self.requiresExternalAudioActivation = requiresExternalAudioActivation
        self.onEvent = onEvent
        self.api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: allowInsecureHttp)
        if let pairwiseCrypto {
            self.crypto = pairwiseCrypto
        } else {
            self.crypto = try PersistentPairwiseCrypto(
                session: session,
                store: signalStore,
                allowInsecureHttp: allowInsecureHttp
            )
        }
        self.historyArchive = try SecureVoiceHistoryArchive(
            namespace: "app.ptt.talk.history.v1.\(session.aci).\(session.deviceId)"
        )
    }

    public func publishPreKeys(
        initialBatchSize: Int = 100,
        replenishmentBatchSize: Int = 20
    ) async {
        do {
            try await crypto.ensurePreKeysPublished(
                initialBatchSize: initialBatchSize,
                replenishmentBatchSize: replenishmentBatchSize
            )
        } catch {
            reportFailure(error, context: "Prekey publication failed")
        }
    }

    public func prepare(_ selectedChannel: ChannelSummary) async {
        onEvent(.preparing(selectedChannel.displayName))
        relayAvailable = false
        if outgoing != nil || floorToken != nil { await endTransmit() }
        stopMediaAndRelay()
        channel = selectedChannel
        lastChannelMetadataRefresh = Date()
        do {
            if !requiresExternalAudioActivation { try audio.preparePlayback() }
            async let issuedRequest = api.relayCredential(session: session, channelId: selectedChannel.channelId)
            async let devicesRequest = api.channelDevices(session: session, channelId: selectedChannel.channelId)
            async let fastFloorRequest = api.supportsCapability("media-floor-control-v1")
            let issued = try await issuedRequest
            let connected = try await AdaptiveMediaRelay.connect(
                serverUrl: session.serverUrl,
                accessToken: session.accessToken,
                channelId: try requiredUuid(selectedChannel.channelId),
                publicAddress: issued.relayAddress,
                ticket: issued.ticket,
                expectedSenderDemux: issued.senderDemux,
                supportsFastFloor: try await fastFloorRequest,
                onMedia: { [weak self] packet in
                    Task { await self?.receive(packet) }
                },
                onConnectionStateChanged: { [weak self] state in
                    Task { await self?.relayConnectionChanged(state, channelId: selectedChannel.channelId) }
                }
            )
            credential = issued
            relay = connected
            relayAvailable = true
            cachedChannelDevices = try await devicesRequest
            cachedDevicesChannelId = selectedChannel.channelId
            cachedDevicesMembershipEpoch = selectedChannel.membershipEpoch
            onEvent(.relayState(.connected(transport: connected.transportName)))
            scheduleRelayRefresh(issued, channelId: selectedChannel.channelId)
            startMailboxLoop()
            startPlayoutLoop()
            startHistorySyncLoop()
            startPresenceLoop()
            let detail = selectedChannel.role == "listen"
                ? "Listening to \(selectedChannel.displayName); this role cannot transmit."
                : "\(selectedChannel.displayName) is ready."
            onEvent(.ready(detail))
        } catch {
            reportFailure(error, context: "Channel preparation failed")
            guard !isUnauthorized(error) else { return }
            onEvent(.relayState(.unavailable))
            relayRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.refreshRelay(channelId: selectedChannel.channelId)
            }
        }
    }

    public func beginTransmit(sos: Bool = false, silent: Bool = false) async {
        // A release flushes media and returns the authenticated floor. If the
        // user presses again during that short async teardown, preserve the
        // held request instead of silently dropping it.
        if endingTransmit {
            for _ in 0..<80 where endingTransmit {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        guard !endingTransmit, outgoing == nil, floorToken == nil else {
            onEvent(.floorDenied("Finishing the previous transmission. Keep holding and try again."))
            return
        }
        let attempt = transmitAttempts.begin()
        let establishmentStartedAt = DispatchTime.now().uptimeNanoseconds
        let shouldPrepareCapture = !silent && VoiceAudioActivationGate.canUseAudio(
            requiresExternalActivation: requiresExternalAudioActivation,
            externalAudioActive: externalAudioActive
        )
        do {
            // The floor endpoint revalidates membership, role, relay lease, and
            // membership epoch. Use the prepared channel immediately and only
            // pay for a metadata refresh if the server reports a stale epoch.
            guard var channel = self.channel,
                  var credential = self.credential,
                  var relay = self.relay,
                  relayAvailable else {
                onEvent(.error("Select and prepare a channel first."))
                return
            }
            guard channel.role != "listen" else {
                onEvent(.floorDenied("Your channel role cannot transmit."))
                return
            }
            guard !relayRefreshing else {
                onEvent(.floorDenied("The encrypted relay is refreshing. Try again in a moment."))
                return
            }
            let audio = self.audio
            let capturePreparation: Task<Void, Error>? = shouldPrepareCapture
                ? Task.detached(priority: .userInitiated) { try audio.prepareCapture() }
                : nil
            onEvent(.requestingFloor)
            let grant: FloorGrant
            let requestToken = Data.random(count: 16).base64Url
            do {
                if let fastGrant = try? await relay.requestFloor(
                    requestToken: requestToken, membershipEpoch: channel.membershipEpoch,
                    requestedTotMs: silent ? 1_000 : 30_000, sos: sos
                ) {
                    grant = FloorGrant(
                        granted: fastGrant.granted, requestToken: fastGrant.requestToken,
                        grantedTotMs: fastGrant.grantedTotMs, reason: fastGrant.reason
                    )
                } else {
                    grant = try await api.requestFloor(
                        session: session, channel: channel, relay: credential,
                        requestToken: requestToken, requestedTotMs: silent ? 1_000 : 30_000, sos: sos
                    )
                }
            } catch let ControlApiError.server(status, code)
                where FloorRequestMetadataPolicy.requiresRefresh(status: status, code: code) {
                guard let refreshed = try await refreshChannelMetadata(force: true) else { return }
                channel = refreshed
                guard let refreshedCredential = self.credential,
                      let refreshedRelay = self.relay,
                      relayAvailable else {
                    onEvent(.error("The encrypted relay could not refresh for the updated channel membership."))
                    return
                }
                credential = refreshedCredential
                relay = refreshedRelay
                grant = try await api.requestFloor(
                    session: session,
                    channel: channel,
                    relay: credential,
                    requestToken: requestToken,
                    requestedTotMs: silent ? 1_000 : 30_000,
                    sos: sos
                )
            }
            guard grant.granted else {
                onEvent(.floorDenied(grant.reason ?? "The channel is busy."))
                return
            }
            guard transmitAttempts.isCurrent(attempt) else {
                try? await api.releaseFloor(
                    session: session,
                    channelId: channel.channelId,
                    requestToken: grant.requestToken
                )
                return
            }
            floorToken = grant.requestToken
            let floorLatencyMs = (DispatchTime.now().uptimeNanoseconds - establishmentStartedAt) / 1_000_000
            voiceLatencyLogger.info("floor_grant_latency_ms=\(floorLatencyMs, privacy: .public)")
            onEvent(.floorGranted(latencyMs: floorLatencyMs))
            if shouldPrepareCapture {
                // Prove that this device has a usable microphone route before
                // distributing a media epoch or creating an outgoing stream.
                // A local audio failure must not look like a real encrypted talk.
                try await capturePreparation?.value
            }
            let announcement = MediaEpochAnnouncement(
                channelId: try requiredUuid(channel.channelId),
                talkId: UUID(),
                membershipEpoch: Int32(channel.membershipEpoch),
                senderDemux: credential.senderDemux,
                kid: UInt64.random(in: 1...UInt64.max),
                baseKey: Data.random(count: 32),
                totMs: Int32(grant.grantedTotMs),
                isSos: sos
            )
            let devices = try await channelDevicesForTransmit(channel)
            let acceptedRecipients = try await crypto.announceMediaEpoch(
                devices: devices,
                distributionId: try requiredUuid(channel.distributionId),
                announcement: announcement
            )
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-sender") {
                NSLog(
                    "PTT_E2E_EPOCH_ENQUEUED talk=%@ recipients=%d",
                    announcement.talkId.uuidString,
                    acceptedRecipients
                )
            }
#endif
            guard transmitAttempts.isCurrent(attempt), floorToken == grant.requestToken else { return }
            try historyArchive.putEpoch(
                announcement,
                senderAci: session.aci,
                senderDeviceId: session.deviceId
            )
            let collector = HistoryPacketCollector()
            let transmitRelay = relay
            let recordedStream = try OutgoingVoiceStream(
                announcement: announcement,
                demuxToken: credential.demuxToken,
                signalStore: store,
                counterStream: "\(channel.channelId)/\(session.deviceId)",
                onPacketSent: { packet in collector.append(packet) }
            ) { packet in try transmitRelay.send(packet) }
            outgoing = recordedStream
            outgoingAnnouncement = announcement
            outgoingStartedAt = Date()
            historyCollector = collector
            if !silent && VoiceAudioActivationGate.canUseAudio(
                requiresExternalActivation: requiresExternalAudioActivation,
                externalAudioActive: externalAudioActive
            ) { try startCapture() }
            let readyLatencyMs = (DispatchTime.now().uptimeNanoseconds - establishmentStartedAt) / 1_000_000
            voiceLatencyLogger.info("communication_ready_latency_ms=\(readyLatencyMs, privacy: .public)")
            onEvent(.transmitting(
                details(
                    announcement: announcement,
                    senderAci: session.aci,
                    senderDeviceId: session.deviceId
                ),
                readyLatencyMs: readyLatencyMs
            ))
            floorTimeoutTask?.cancel()
            floorTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(grant.grantedTotMs))
                guard !Task.isCancelled else { return }
                await self?.endTransmit()
            }
            if silent { await endTransmit() }
        } catch {
            guard transmitAttempts.isCurrent(attempt) else { return }
            reportFailure(error, context: "Could not start transmission")
            await endTransmit()
        }
    }

    public func endTransmit() async {
        guard !endingTransmit else { return }
        endingTransmit = true
        transmitAttempts.cancel()
        floorTimeoutTask?.cancel()
        floorTimeoutTask = nil
        audio.stopCapture()
        captureStarted = false
        let outgoingStream = outgoing
        outgoingStream?.close()
        outgoing = nil
        let announcement = outgoingAnnouncement
        let startedAt = outgoingStartedAt
        let packets = historyCollector?.snapshot() ?? []
        outgoingAnnouncement = nil
        outgoingStartedAt = nil
        historyCollector = nil
        let token = floorToken
        if outgoingStream != nil, let relay {
            do { try await relay.flush() }
            catch { reportFailure(error, context: "Voice delivery finalization failed") }
        }
        floorToken = nil
        if let token, let channel {
            do { try await api.releaseFloor(session: session, channelId: channel.channelId, requestToken: token) }
            catch { reportFailure(error, context: "Floor release failed") }
        }
        endingTransmit = false
        if let channel { onEvent(.ready("\(channel.displayName) is ready.")) }
        if let announcement, let startedAt, !packets.isEmpty {
            Task { [weak self] in
                await self?.archiveTransmission(
                    announcement: announcement,
                    startedAt: startedAt,
                    packets: packets
                )
            }
        }
    }

    private func archiveTransmission(
        announcement: MediaEpochAnnouncement,
        startedAt: Date,
        packets: [Data]
    ) async {
        do {
            let ciphertext = try EncryptedHistory.seal(
                channelId: announcement.channelId,
                talkId: announcement.talkId,
                membershipEpoch: announcement.membershipEpoch,
                kid: announcement.kid,
                baseKey: announcement.baseKey,
                packets: packets
            )
            let metadata = try await api.uploadHistory(
                session: session,
                announcement: announcement,
                startedAt: startedAt,
                durationMs: min(30_000, packets.count * 20),
                ciphertext: ciphertext
            )
            try historyArchive.complete(metadata: metadata, ciphertext: ciphertext)
            onEvent(.historyUpdated)
        } catch {
            reportFailure(error, context: "Encrypted history upload failed")
        }
    }

    public func shutdown() async {
        await endTransmit()
        mailboxTask?.cancel()
        mailboxTask = nil
        historySyncTask?.cancel()
        historySyncTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        stopMediaAndRelay()
    }

    public func setPresence(_ mode: String) async {
        guard ["available", "busy", "solo", "standby"].contains(mode) else {
            onEvent(.error("Invalid presence mode."))
            return
        }
        presenceMode = mode
        do { try await api.setPresence(session: session, mode: mode) }
        catch { reportFailure(error, context: "Presence update failed") }
    }

    public func historyItems() throws -> [VoiceHistoryItem] {
        guard let channel, let channelId = UUID(uuidString: channel.channelId) else { return [] }
        return try historyArchive.records(channelId: channelId).compactMap { record in
            guard let startedAt = record.startedAt,
                  let durationMs = record.durationMs,
                  let expiresAt = record.expiresAt else { return nil }
            return VoiceHistoryItem(
                talkId: record.talkId,
                channelId: record.channelId,
                senderAci: record.senderAci,
                senderDeviceId: record.senderDeviceId,
                startedAt: startedAt,
                durationMs: durationMs,
                expiresAt: expiresAt,
                isSos: record.isSos ?? false
            )
        }
    }

    public func playHistory(talkId: UUID) async {
        guard outgoing == nil, floorToken == nil, incoming.isEmpty else {
            onEvent(.error("Finish the active transmission before playing history."))
            return
        }
        do {
            guard let record = try historyArchive.record(talkId), let kid = UInt64(record.mediaKid) else {
                throw SecureVoiceHistoryError.missingObject
            }
            let announcement = MediaEpochAnnouncement(
                channelId: record.channelId,
                talkId: record.talkId,
                membershipEpoch: record.membershipEpoch,
                senderDemux: record.senderDemux,
                kid: kid,
                baseKey: record.baseKey,
                totMs: Int32(record.durationMs ?? 30_000),
                isSos: record.isSos ?? false
            )
            let stream = try IncomingVoiceStream(
                senderAci: record.senderAci,
                senderDeviceId: record.senderDeviceId,
                announcement: announcement
            )
            incoming[talkId] = stream
            onEvent(.receiving(details(
                announcement: announcement,
                senderAci: record.senderAci,
                senderDeviceId: record.senderDeviceId
            )))
            let packets = try historyArchive.packets(talkId)
            historyPlaybackTask?.cancel()
            historyPlaybackTask = Task { [weak self, weak stream] in
                for packet in packets {
                    guard !Task.isCancelled, let stream else { return }
                    do { try stream.accept(packet) }
                    catch {
                        await self?.report(error: "History playback failed: \(error.localizedDescription)")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            onEvent(.error("History playback failed: \(error.localizedDescription)"))
        }
    }

    public func setExternalAudioActive(_ active: Bool) {
        externalAudioActive = active
        if active {
            do { try startCapture() }
            catch { onEvent(.error("Microphone activation failed: \(error.localizedDescription)")) }
        } else {
            audio.stopCapture()
            captureStarted = false
        }
    }

    private func startMailboxLoop() {
        mailboxTask?.cancel()
        mailboxTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMailboxCoalesced()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func startPlayoutLoop() {
        playoutTask?.cancel()
        playoutTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.playoutOneFrame()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func startHistorySyncLoop() {
        historySyncTask?.cancel()
        historySyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncHistory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startPresenceLoop() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.api.setPresence(session: self.session, mode: self.presenceMode) }
                catch { await self.reportFailure(error, context: "Presence update failed") }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func playoutOneFrame() {
        // PushToTalk owns AVAudioSession activation on physical iOS devices.
        // Do not drain a short jitter stream before the system has made its
        // output route audible; the queued transmission must remain available
        // for the first playout tick after didActivate.
        guard VoiceAudioActivationGate.canUseAudio(
            requiresExternalActivation: requiresExternalAudioActivation,
            externalAudioActive: externalAudioActive
        ) else { return }
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let inactiveTalkIds = incoming.compactMap { talkId, stream in
            stream.isInactive(nowMs: nowMs) ? talkId : nil
        }
        for talkId in inactiveTalkIds {
            incoming.removeValue(forKey: talkId)?.close()
            receivingTalkIds.remove(talkId)
        }
        if !inactiveTalkIds.isEmpty, incoming.isEmpty, let channel {
            onEvent(.ready("\(channel.displayName) is ready."))
        }
        // If an unreliable UDP end marker was lost, the old jitter buffer can
        // remain in `.buffering` forever. Prefer the stream that received media
        // most recently so a newer authenticated talk is never starved behind it.
        guard let (talkId, stream) = incoming.max(by: {
            ($0.value.lastMediaAtMs ?? 0) < ($1.value.lastMediaAtMs ?? 0)
        }) else { return }
        do {
            let framesToSchedule = VoicePlayoutQueuePolicy.framesToSchedule(
                currentQueued: audio.queuedPlaybackFrameCount()
            )
            for _ in 0..<framesToSchedule {
                switch try stream.pop() {
                case .buffering:
                    return
                case let .frame(pcm, ended, _):
                    try audio.play(pcm)
                    if ended {
                        stream.close()
                        incoming.removeValue(forKey: talkId)
                        receivingTalkIds.remove(talkId)
                        if let channel { onEvent(.ready("\(channel.displayName) is ready.")) }
                        return
                    }
                }
            }
        } catch {
            stream.close()
            incoming.removeValue(forKey: talkId)
            receivingTalkIds.remove(talkId)
            onEvent(.error("Encrypted playout failed: \(error.localizedDescription)"))
        }
    }

    private func pollMailbox() async {
        do {
            guard let channel = try await refreshChannelMetadata() else { return }
            let items = try await api.mailboxItems(session: session, limit: 25)
            guard !items.isEmpty else { return }
            let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
            var accepted: [String] = []
            for item in items {
                do {
                    let opened = try await crypto.decryptEnvelope(
                        item.envelope,
                        allowedDevices: devices,
                        expectedDistributionId: try requiredUuid(channel.distributionId)
                    )
                    guard opened.announcement.channelId.uuidString.lowercased() == channel.channelId.lowercased(),
                          Int(opened.announcement.membershipEpoch) == channel.membershipEpoch else {
                        // A valid announcement for a membership epoch this
                        // device no longer uses must never block current voice.
                        accepted.append(item.itemId)
                        continue
                    }
                    try historyArchive.putEpoch(
                        opened.announcement,
                        senderAci: opened.senderAci,
                        senderDeviceId: opened.senderDeviceId
                    )
                    incoming[opened.announcement.talkId]?.close()
                    receivingTalkIds.remove(opened.announcement.talkId)
                    incoming[opened.announcement.talkId] = try IncomingVoiceStream(
                        senderAci: opened.senderAci,
                        senderDeviceId: opened.senderDeviceId,
                        announcement: opened.announcement
                    )
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                        NSLog("PTT_E2E_EPOCH_ACCEPT talk=%@", opened.announcement.talkId.uuidString)
                    }
#endif
                    accepted.append(item.itemId)
                } catch let error as SignalError {
                    // Missing sessions can become valid after an overtaking
                    // prekey message. Every other libsignal failure is terminal
                    // for this immutable ciphertext, including a proven replay.
                    if case .sessionNotFound = error {
#if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                            NSLog("PTT_E2E_EPOCH_RETRY message=%@ reason=session-not-found", item.messageId)
                        }
#endif
                        continue
                    }
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                        NSLog(
                            "PTT_E2E_EPOCH_DROP message=%@ signal=%@",
                            item.messageId,
                            String(reflecting: error)
                        )
                    }
#endif
                    accepted.append(item.itemId)
                } catch let error as PersistentCryptoError {
                    // Invalid, unauthorized, or stale immutable envelopes fail
                    // closed and are removed so they cannot starve the mailbox.
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                        NSLog(
                            "PTT_E2E_EPOCH_DROP message=%@ validation=%@",
                            item.messageId,
                            String(reflecting: error)
                        )
                    }
#endif
                    accepted.append(item.itemId)
                }
            }
            if !accepted.isEmpty {
                _ = try await api.acknowledgeMailbox(session: session, itemIds: accepted)
                replayPendingPackets()
            }
        } catch {
            reportFailure(error, context: "Mailbox delivery failed")
        }
    }

    private func refreshChannelMetadata(force: Bool = false) async throws -> ChannelSummary? {
        guard let selected = channel else { return nil }
        let now = Date()
        if !force, now.timeIntervalSince(lastChannelMetadataRefresh) < 2 { return selected }
        let fresh = try await api.channels(session: session).first { $0.channelId == selected.channelId }
        lastChannelMetadataRefresh = now
        guard let fresh else {
            relayRefreshTask?.cancel()
            relayRefreshTask = nil
            relay?.close()
            relay = nil
            credential = nil
            channel = nil
            for stream in incoming.values { stream.close() }
            incoming.removeAll()
            pendingPackets.removeAll()
            onEvent(.floorDenied("You no longer have access to this channel."))
            return nil
        }
        let rotated = fresh.membershipEpoch != selected.membershipEpoch
            || fresh.distributionId != selected.distributionId
            || fresh.role != selected.role
        channel = fresh
        if rotated {
            cachedChannelDevices = []
            cachedDevicesChannelId = nil
            cachedDevicesMembershipEpoch = nil
            onEvent(.preparing("Channel membership changed; rotating sender keys…"))
            await refreshRelay(channelId: fresh.channelId)
        }
        return fresh
    }

    private func channelDevicesForTransmit(_ channel: ChannelSummary) async throws -> [ChannelDevice] {
        if cachedDevicesChannelId == channel.channelId,
           cachedDevicesMembershipEpoch == channel.membershipEpoch,
           !cachedChannelDevices.isEmpty {
            return cachedChannelDevices
        }
        let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
        cachedChannelDevices = devices
        cachedDevicesChannelId = channel.channelId
        cachedDevicesMembershipEpoch = channel.membershipEpoch
        return devices
    }

    private func syncHistory() async {
        guard let channel, let channelId = UUID(uuidString: channel.channelId) else { return }
        do {
            let remote = try await api.history(session: session, channelId: channelId, limit: 100)
            for metadata in remote {
                guard let local = try historyArchive.record(metadata.talkId), local.objectId == nil,
                      local.channelId == metadata.channelId,
                      Int(local.membershipEpoch) == metadata.membershipEpoch,
                      local.mediaKid == String(metadata.mediaKid) else { continue }
                let downloaded = try await api.downloadHistory(session: session, objectId: metadata.objectId)
                guard downloaded.metadata == metadata else { throw ControlApiError.invalidResponse }
                try historyArchive.complete(metadata: metadata, ciphertext: downloaded.ciphertext)
                onEvent(.historyUpdated)
            }
        } catch {
            reportFailure(error, context: "History sync failed")
        }
    }

    private func receive(_ packet: Data) {
        if let (talkId, stream) = incoming.first(where: { $0.value.matches(packet) }) {
            do {
                guard try stream.accept(packet) else { return }
                if receivingTalkIds.insert(talkId).inserted {
                    // A system-managed Push to Talk audio session is activated
                    // only after the app identifies the remote participant. Do
                    // that as soon as the first authenticated media packet is
                    // accepted, before the playout gate checks audio activation.
                    // This also binds test instrumentation to the correct talk
                    // before its first decoded frame is scheduled.
                    onEvent(.receiving(details(
                        announcement: stream.announcement,
                        senderAci: stream.senderAci,
                        senderDeviceId: stream.senderDeviceId
                    )))
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ptt-e2e-receiver") {
                        NSLog("PTT_E2E_MEDIA_FIRST_ACCEPT talk=%@", talkId.uuidString)
                    }
#endif
                }
            } catch {
                onEvent(.error("Encrypted media was rejected: \(error.localizedDescription)"))
            }
            return
        }
        // Media can legitimately beat its pairwise epoch announcement when
        // mailbox traffic and attachment delivery are busy. Retain a bounded
        // ten-second pre-key window so an authenticated talk is replayed after
        // its key arrives instead of becoming silent. The packet cap keeps the
        // unauthenticated pre-decryption memory budget below a few megabytes.
        let cutoff = Date().addingTimeInterval(-10)
        pendingPackets.removeAll { $0.receivedAt < cutoff }
        if pendingPackets.count >= 1_000 { pendingPackets.removeFirst() }
        pendingPackets.append(PendingPacket(receivedAt: Date(), data: packet))
        expediteMailboxDelivery()
    }

    private func expediteMailboxDelivery() {
        guard mailboxWakeGate.begin() else { return }
        Task { [weak self] in
            await self?.runMailboxPollLoop()
        }
    }

    private func pollMailboxCoalesced() async {
        guard mailboxWakeGate.begin() else { return }
        await runMailboxPollLoop()
    }

    private func runMailboxPollLoop() async {
        repeat {
            await pollMailbox()
        } while mailboxWakeGate.finish()
    }

    private func replayPendingPackets() {
        let buffered = pendingPackets
        pendingPackets.removeAll(keepingCapacity: true)
        for item in buffered { receive(item.data) }
    }

    private func stopMediaAndRelay() {
        mailboxTask?.cancel()
        mailboxTask = nil
        playoutTask?.cancel()
        playoutTask = nil
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        historySyncTask?.cancel()
        historySyncTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        historyPlaybackTask?.cancel()
        historyPlaybackTask = nil
        relayRefreshing = false
        relay?.close()
        relay = nil
        relayAvailable = false
        credential = nil
        channel = nil
        cachedChannelDevices = []
        cachedDevicesChannelId = nil
        cachedDevicesMembershipEpoch = nil
        for stream in incoming.values { stream.close() }
        incoming.removeAll()
        receivingTalkIds.removeAll()
        pendingPackets.removeAll()
        mailboxWakeGate = VoiceMailboxWakeGate()
    }

    private func scheduleRelayRefresh(_ issued: RelayCredential, channelId: String) {
        relayRefreshTask?.cancel()
        let delay = max(1, issued.expiresAt.timeIntervalSinceNow - 60)
        relayRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshRelay(channelId: channelId)
        }
    }

    private func refreshRelay(channelId: String) async {
        guard channel?.channelId == channelId else { return }
        if outgoing != nil || floorToken != nil {
            relayRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.refreshRelay(channelId: channelId)
            }
            return
        }
        guard !relayRefreshing else { return }
        relayRefreshing = true
        defer { relayRefreshing = false }
        do {
            let issued = try await api.relayCredential(session: session, channelId: channelId)
            let supportsFastFloor = try await api.supportsCapability("media-floor-control-v1")
            let connected = try await AdaptiveMediaRelay.connect(
                serverUrl: session.serverUrl,
                accessToken: session.accessToken,
                channelId: try requiredUuid(channelId),
                publicAddress: issued.relayAddress,
                ticket: issued.ticket,
                expectedSenderDemux: issued.senderDemux,
                supportsFastFloor: supportsFastFloor,
                onMedia: { [weak self] packet in Task { await self?.receive(packet) } },
                onConnectionStateChanged: { [weak self] state in
                    Task { await self?.relayConnectionChanged(state, channelId: channelId) }
                }
            )
            guard channel?.channelId == channelId, outgoing == nil, floorToken == nil else {
                connected.close()
                return
            }
            let previous = relay
            relay = connected
            credential = issued
            relayAvailable = true
            previous?.close()
            scheduleRelayRefresh(issued, channelId: channelId)
            onEvent(.relayState(.connected(transport: connected.transportName)))
            onEvent(.ready("\(channel?.displayName ?? "Channel") relay security refreshed."))
        } catch {
            reportFailure(error, context: "Relay credential refresh failed")
            guard !isUnauthorized(error) else { return }
            onEvent(.relayState(.unavailable))
            relayRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.refreshRelay(channelId: channelId)
            }
        }
    }

    private func report(error: String) { onEvent(.error(error)) }

    private func relayConnectionChanged(
        _ state: MediaRelayConnectionState,
        channelId: String
    ) async {
        guard channel?.channelId == channelId else { return }
        switch state {
        case .reconnecting:
            relayAvailable = false
            if outgoing != nil || floorToken != nil { await endTransmit() }
            onEvent(.relayState(state))
        case .connected:
            relayAvailable = true
            onEvent(.relayState(state))
        case .unavailable:
            relayAvailable = false
            onEvent(.relayState(state))
            await refreshRelay(channelId: channelId)
        }
    }

    private func reportFailure(_ error: Error, context: String) {
        if isUnauthorized(error) {
            guard !revoked else { return }
            revoked = true
            stopMediaAndRelay()
            onEvent(.deviceRevoked)
        } else {
            onEvent(.error("\(context): \(error.localizedDescription)"))
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        guard case let ControlApiError.server(status, _) = error else { return false }
        return status == 401
    }

    private func report(ready: String) { onEvent(.ready(ready)) }

    private func startCapture() throws {
        guard !captureStarted, let outgoing else { return }
        try audio.startCapture { [weak self, weak outgoing] pcm in
            do { try outgoing?.send(pcm: pcm) }
            catch {
                guard VoiceCaptureSendFailurePolicy.shouldReport(error) else { return }
                Task { await self?.report(error: "Voice transmission failed: \(error.localizedDescription)") }
            }
        }
        captureStarted = true
    }

    private func details(
        announcement: MediaEpochAnnouncement,
        senderAci: String,
        senderDeviceId: Int
    ) -> VoiceEncryptionDetails {
        VoiceEncryptionDetails(
            algorithm: "RFC 9605 SFrame AES-128-GCM / Opus 48 kHz",
            keyEstablishment: "PQXDH + Double Ratchet authenticated Sender Keys",
            channelId: announcement.channelId,
            talkId: announcement.talkId,
            senderDemux: announcement.senderDemux,
            kid: announcement.kid,
            membershipEpoch: Int(announcement.membershipEpoch),
            senderAci: senderAci,
            senderDeviceId: senderDeviceId,
            isSos: announcement.isSos
        )
    }
}

private func requiredUuid(_ value: String) throws -> UUID {
    guard let value = UUID(uuidString: value) else { throw ControlApiError.invalidResponse }
    return value
}
