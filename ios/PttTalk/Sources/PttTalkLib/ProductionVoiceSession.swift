import Foundation

public protocol VoiceAudioIO: AnyObject, Sendable {
    func startCapture(onFrame: @escaping @Sendable ([Int16]) -> Void) throws
    func stopCapture()
    func play(_ pcm: [Int16]) throws
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
}

public enum VoiceSessionEvent: Equatable, Sendable {
    case preparing(String)
    case ready(String)
    case requestingFloor
    case floorDenied(String)
    case transmitting(VoiceEncryptionDetails)
    case receiving(VoiceEncryptionDetails)
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
    private let audio: VoiceAudioIO
    private let requiresExternalAudioActivation: Bool
    private let onEvent: @Sendable (VoiceSessionEvent) -> Void
    private var channel: ChannelSummary?
    private var credential: RelayCredential?
    private var relay: MediaRelay?
    private var outgoing: OutgoingVoiceStream?
    private var floorToken: String?
    private var incoming: [UUID: IncomingVoiceStream] = [:]
    private var pendingPackets: [PendingPacket] = []
    private var mailboxTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?
    private var floorTimeoutTask: Task<Void, Never>?
    private var relayRefreshTask: Task<Void, Never>?
    private var relayRefreshing = false
    private var externalAudioActive = false
    private var captureStarted = false

    public init(
        session: DeviceSession,
        signalStore: KeychainSignalProtocolStore,
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
        self.crypto = try PersistentPairwiseCrypto(
            session: session,
            store: signalStore,
            allowInsecureHttp: allowInsecureHttp
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
            onEvent(.error("Prekey publication failed: \(error.localizedDescription)"))
        }
    }

    public func prepare(_ selectedChannel: ChannelSummary) async {
        onEvent(.preparing(selectedChannel.displayName))
        if outgoing != nil || floorToken != nil { await endTransmit() }
        stopMediaAndRelay()
        do {
            let issued = try await api.relayCredential(session: session, channelId: selectedChannel.channelId)
            let connected = try await AdaptiveMediaRelay.connect(
                serverUrl: session.serverUrl,
                accessToken: session.accessToken,
                channelId: try requiredUuid(selectedChannel.channelId),
                publicAddress: issued.relayAddress,
                ticket: issued.ticket,
                expectedSenderDemux: issued.senderDemux,
                onMedia: { [weak self] packet in
                    Task { await self?.receive(packet) }
                },
                onError: { [weak self] error in
                    Task { await self?.report(error: "Relay failed: \(error.localizedDescription)") }
                },
                onTransportChanged: { [weak self] detail in
                    Task { await self?.report(ready: detail) }
                }
            )
            channel = selectedChannel
            credential = issued
            relay = connected
            scheduleRelayRefresh(issued, channelId: selectedChannel.channelId)
            startMailboxLoop()
            startPlayoutLoop()
            let detail = selectedChannel.role == "listen"
                ? "Listening to \(selectedChannel.displayName); this role cannot transmit."
                : "\(selectedChannel.displayName) is ready."
            onEvent(.ready(detail))
        } catch {
            onEvent(.error("Channel preparation failed: \(error.localizedDescription)"))
        }
    }

    public func beginTransmit() async {
        guard outgoing == nil, floorToken == nil else { return }
        guard let channel, let credential, let relay else {
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
        onEvent(.requestingFloor)
        do {
            let grant = try await api.requestFloor(session: session, channel: channel, relay: credential)
            guard grant.granted else {
                onEvent(.floorDenied(grant.reason ?? "The channel is busy."))
                return
            }
            floorToken = grant.requestToken
            let announcement = MediaEpochAnnouncement(
                channelId: try requiredUuid(channel.channelId),
                talkId: UUID(),
                membershipEpoch: Int32(channel.membershipEpoch),
                senderDemux: credential.senderDemux,
                kid: UInt64.random(in: UInt64.min...UInt64.max),
                baseKey: Data.random(count: 32),
                totMs: Int32(grant.grantedTotMs)
            )
            let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
            _ = try await crypto.announceMediaEpoch(devices: devices, announcement: announcement)
            try await Task.sleep(for: .milliseconds(300))

            let stream = try OutgoingVoiceStream(
                announcement: announcement,
                demuxToken: credential.demuxToken,
                signalStore: store,
                counterStream: "\(channel.channelId)/\(session.deviceId)"
            ) { packet in try relay.send(packet) }
            outgoing = stream
            if !requiresExternalAudioActivation || externalAudioActive { try startCapture() }
            onEvent(.transmitting(details(
                announcement: announcement,
                senderAci: session.aci,
                senderDeviceId: session.deviceId
            )))
            floorTimeoutTask?.cancel()
            floorTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(grant.grantedTotMs))
                guard !Task.isCancelled else { return }
                await self?.endTransmit()
            }
        } catch {
            onEvent(.error("Could not start transmission: \(error.localizedDescription)"))
            await endTransmit()
        }
    }

    public func endTransmit() async {
        floorTimeoutTask?.cancel()
        floorTimeoutTask = nil
        audio.stopCapture()
        captureStarted = false
        outgoing?.close()
        outgoing = nil
        let token = floorToken
        floorToken = nil
        if let token, let channel {
            do { try await api.releaseFloor(session: session, channelId: channel.channelId, requestToken: token) }
            catch { onEvent(.error("Floor release failed: \(error.localizedDescription)")) }
        }
        if let channel { onEvent(.ready("\(channel.displayName) is ready.")) }
    }

    public func shutdown() async {
        await endTransmit()
        mailboxTask?.cancel()
        mailboxTask = nil
        stopMediaAndRelay()
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
                await self?.pollMailbox()
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

    private func playoutOneFrame() {
        guard let (talkId, stream) = incoming.first else { return }
        do {
            switch try stream.pop() {
            case .buffering:
                break
            case let .frame(pcm, ended, _):
                try audio.play(pcm)
                if ended {
                    stream.close()
                    incoming.removeValue(forKey: talkId)
                    if let channel { onEvent(.ready("\(channel.displayName) is ready.")) }
                }
            }
        } catch {
            stream.close()
            incoming.removeValue(forKey: talkId)
            onEvent(.error("Encrypted playout failed: \(error.localizedDescription)"))
        }
    }

    private func pollMailbox() async {
        guard let channel else { return }
        do {
            let items = try await api.mailboxItems(session: session, limit: 25)
            guard !items.isEmpty else { return }
            let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
            var accepted: [String] = []
            for item in items {
                guard let opened = try? await crypto.decryptEnvelope(item.envelope, allowedDevices: devices),
                      opened.announcement.channelId.uuidString.lowercased() == channel.channelId.lowercased(),
                      Int(opened.announcement.membershipEpoch) == channel.membershipEpoch else { continue }
                incoming[opened.announcement.talkId]?.close()
                incoming[opened.announcement.talkId] = try IncomingVoiceStream(
                    senderAci: opened.senderAci,
                    senderDeviceId: opened.senderDeviceId,
                    announcement: opened.announcement
                )
                accepted.append(item.itemId)
                onEvent(.receiving(details(
                    announcement: opened.announcement,
                    senderAci: opened.senderAci,
                    senderDeviceId: opened.senderDeviceId
                )))
            }
            if !accepted.isEmpty {
                _ = try await api.acknowledgeMailbox(session: session, itemIds: accepted)
                replayPendingPackets()
            }
        } catch {
            onEvent(.error("Mailbox delivery failed: \(error.localizedDescription)"))
        }
    }

    private func receive(_ packet: Data) {
        if let stream = incoming.values.first(where: { $0.matches(packet) }) {
            do {
                try stream.accept(packet)
            } catch {
                onEvent(.error("Encrypted media was rejected: \(error.localizedDescription)"))
            }
            return
        }
        let cutoff = Date().addingTimeInterval(-2)
        pendingPackets.removeAll { $0.receivedAt < cutoff }
        if pendingPackets.count >= 100 { pendingPackets.removeFirst() }
        pendingPackets.append(PendingPacket(receivedAt: Date(), data: packet))
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
        relayRefreshing = false
        relay?.close()
        relay = nil
        credential = nil
        channel = nil
        for stream in incoming.values { stream.close() }
        incoming.removeAll()
        pendingPackets.removeAll()
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
            let connected = try await AdaptiveMediaRelay.connect(
                serverUrl: session.serverUrl,
                accessToken: session.accessToken,
                channelId: try requiredUuid(channelId),
                publicAddress: issued.relayAddress,
                ticket: issued.ticket,
                expectedSenderDemux: issued.senderDemux,
                onMedia: { [weak self] packet in Task { await self?.receive(packet) } },
                onError: { [weak self] error in
                    Task { await self?.report(error: "Relay failed: \(error.localizedDescription)") }
                },
                onTransportChanged: { [weak self] detail in
                    Task { await self?.report(ready: detail) }
                }
            )
            guard channel?.channelId == channelId, outgoing == nil, floorToken == nil else {
                connected.close()
                return
            }
            let previous = relay
            relay = connected
            credential = issued
            previous?.close()
            scheduleRelayRefresh(issued, channelId: channelId)
            onEvent(.ready("\(channel?.displayName ?? "Channel") relay security refreshed."))
        } catch {
            onEvent(.error("Relay credential refresh failed: \(error.localizedDescription)"))
            relayRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.refreshRelay(channelId: channelId)
            }
        }
    }

    private func report(error: String) { onEvent(.error(error)) }

    private func report(ready: String) { onEvent(.ready(ready)) }

    private func startCapture() throws {
        guard !captureStarted, let outgoing else { return }
        try audio.startCapture { [weak self, weak outgoing] pcm in
            do { try outgoing?.send(pcm: pcm) }
            catch {
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
            keyEstablishment: "PQXDH + Double Ratchet per-device fan-out",
            channelId: announcement.channelId,
            talkId: announcement.talkId,
            senderDemux: announcement.senderDemux,
            kid: announcement.kid,
            membershipEpoch: Int(announcement.membershipEpoch),
            senderAci: senderAci,
            senderDeviceId: senderDeviceId
        )
    }
}

private func requiredUuid(_ value: String) throws -> UUID {
    guard let value = UUID(uuidString: value) else { throw ControlApiError.invalidResponse }
    return value
}
