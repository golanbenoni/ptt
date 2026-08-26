import Foundation
import PttTalkLib

private let senderNamespace = "app.ptt.talk.production-probe.sender.v1"
private let receiverNamespace = "app.ptt.talk.production-probe.receiver.v1"

private final class PacketInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) { lock.withLock { packets.append(packet) } }
    func snapshot() -> [Data] { lock.withLock { packets } }
}

@main
enum ProductionVoiceProbe {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "identities":
            try printFreshIdentities()
        case "run":
            try await run()
        default:
            throw ProbeError("usage: ProductionVoiceProbe identities|run")
        }
    }

    private static func printFreshIdentities() throws {
        try KeychainSignalProtocolStore.resetLocalDeviceState(namespace: senderNamespace)
        try KeychainSignalProtocolStore.resetLocalDeviceState(namespace: receiverNamespace)
        let sender = try KeychainSignalProtocolStore(namespace: senderNamespace)
        let receiver = try KeychainSignalProtocolStore(namespace: receiverNamespace)
        let data = try JSONSerialization.data(withJSONObject: [
            "senderIdentity": sender.identityPublicKey.base64Url,
            "receiverIdentity": receiver.identityPublicKey.base64Url,
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func run() async throws {
        let server = try environment("PTT_E2E_SERVER")
        let aci = try environment("PTT_E2E_ACI")
        let channelId = try environment("PTT_E2E_CHANNEL_ID")
        let sender = DeviceSession(
            serverUrl: server,
            aci: aci,
            deviceId: 1,
            mailboxId: try environment("PTT_E2E_SENDER_MAILBOX"),
            accessToken: try environment("PTT_E2E_SENDER_TOKEN")
        )
        let receiver = DeviceSession(
            serverUrl: server,
            aci: aci,
            deviceId: 2,
            mailboxId: try environment("PTT_E2E_RECEIVER_MAILBOX"),
            accessToken: try environment("PTT_E2E_RECEIVER_TOKEN")
        )
        let api = try ControlApi(serverUrl: server)
        guard let channel = try await api.channels(session: sender).first(where: { $0.channelId == channelId }),
              let channelUuid = UUID(uuidString: channel.channelId),
              let distributionId = UUID(uuidString: channel.distributionId) else {
            throw ProbeError("automation channel is unavailable")
        }

        let senderStore = try KeychainSignalProtocolStore(namespace: senderNamespace)
        let receiverStore = try KeychainSignalProtocolStore(namespace: receiverNamespace)
        let senderCrypto = try PersistentPairwiseCrypto(session: sender, store: senderStore)
        let receiverCrypto = try PersistentPairwiseCrypto(session: receiver, store: receiverStore)
        try await senderCrypto.ensurePreKeysPublished(initialBatchSize: 10)
        try await receiverCrypto.ensurePreKeysPublished(initialBatchSize: 10)
        let devices = try await api.channelDevices(session: sender, channelId: channel.channelId)
        guard devices.count == 2 else { throw ProbeError("expected two active automation devices") }

        let senderCredential = try await api.relayCredential(session: sender, channelId: channel.channelId)
        // Every listening socket needs its own active lease even though it does not
        // use the returned demux fields until it becomes a sender.
        _ = try await api.relayCredential(session: receiver, channelId: channel.channelId)
        let inbox = PacketInbox()
        let receiverRelay = try await TlsMediaRelay.connect(
            serverUrl: server,
            accessToken: receiver.accessToken,
            channelId: channelUuid,
            onMedia: inbox.append
        )
        let senderRelay = try await TlsMediaRelay.connect(
            serverUrl: server,
            accessToken: sender.accessToken,
            channelId: channelUuid,
            onMedia: { _ in }
        )

        var floorToken: String?
        do {
            let grant = try await api.requestFloor(
                session: sender,
                channel: channel,
                relay: senderCredential,
                requestedTotMs: 5_000
            )
            guard grant.granted else { throw ProbeError("production floor was denied") }
            floorToken = grant.requestToken
            let announcement = MediaEpochAnnouncement(
                channelId: channelUuid,
                talkId: UUID(),
                membershipEpoch: Int32(channel.membershipEpoch),
                senderDemux: senderCredential.senderDemux,
                kid: UInt64.random(in: 1...UInt64.max),
                baseKey: Data.random(count: 32),
                totMs: Int32(grant.grantedTotMs)
            )
            let recipients = try await senderCrypto.announceMediaEpoch(
                devices: devices,
                distributionId: distributionId,
                announcement: announcement
            )
            guard recipients == 1 else { throw ProbeError("media key was not delivered to exactly one peer") }

            let mailbox = try await waitForMailbox(api: api, session: receiver)
            let opened = try await receiverCrypto.decryptEnvelope(
                mailbox.envelope,
                allowedDevices: devices,
                expectedDistributionId: distributionId
            )
            guard opened.announcement == announcement else { throw ProbeError("receiver opened the wrong media epoch") }
            _ = try await api.acknowledgeMailbox(session: receiver, itemIds: [mailbox.itemId])

            let outgoing = try OutgoingVoiceStream(
                announcement: announcement,
                demuxToken: senderCredential.demuxToken,
                signalStore: senderStore,
                counterStream: "production-probe/\(channel.channelId)"
            ) { packet in try senderRelay.send(packet) }
            for frameIndex in 0..<50 {
                let frame = (0..<voiceSamplesPerFrame).map { sampleIndex in
                    let index = frameIndex * voiceSamplesPerFrame + sampleIndex
                    return Int16(sin(Double(index) * 2 * .pi * 997 / voiceSampleRate) * 20_000)
                }
                try outgoing.send(pcm: frame)
                try await Task.sleep(for: .milliseconds(20))
            }
            outgoing.close()

            let packets = try await waitForPackets(inbox, minimum: 51)
            let incoming = try IncomingVoiceStream(
                senderAci: opened.senderAci,
                senderDeviceId: opened.senderDeviceId,
                announcement: opened.announcement
            )
            for packet in packets { _ = try incoming.accept(packet) }
            var decoded: [Int16] = []
            var ended = false
            for _ in 0..<(packets.count + 20) {
                switch try incoming.pop() {
                case .buffering:
                    continue
                case let .frame(pcm, frameEnded, _):
                    decoded.append(contentsOf: pcm)
                    if frameEnded { ended = true }
                }
                if ended { break }
            }
            let rms = sqrt(decoded.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(decoded.count, 1)))
            guard ended, decoded.count >= 50 * voiceSamplesPerFrame, rms > 5_000 else {
                throw ProbeError("production voice decoded silence or an incomplete stream (samples=\(decoded.count), rms=\(rms))")
            }
            try await api.releaseFloor(session: sender, channelId: channel.channelId, requestToken: grant.requestToken)
            floorToken = nil
            senderRelay.close()
            receiverRelay.close()
            print("production client voice passed: packets=\(packets.count) samples=\(decoded.count) rms=\(Int(rms))")
        } catch {
            if let floorToken {
                try? await api.releaseFloor(session: sender, channelId: channel.channelId, requestToken: floorToken)
            }
            senderRelay.close()
            receiverRelay.close()
            throw error
        }
    }

    private static func waitForMailbox(api: ControlApi, session: DeviceSession) async throws -> MailboxItem {
        for _ in 0..<40 {
            if let item = try await api.mailboxItems(session: session, limit: 10).first { return item }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProbeError("timed out waiting for the encrypted media key")
    }

    private static func waitForPackets(_ inbox: PacketInbox, minimum: Int) async throws -> [Data] {
        for _ in 0..<100 {
            let packets = inbox.snapshot()
            if packets.count >= minimum { return packets }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeError("timed out waiting for encrypted voice packets")
    }

    private static func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ProbeError("\(name) is required")
        }
        return value
    }
}

private struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
