import Foundation
import PttWire

private final class StreamCounterStore: SFrameCounterStore {
    private let store: KeychainSignalProtocolStore
    private let stream: String

    init(store: KeychainSignalProtocolStore, stream: String) {
        self.store = store
        self.stream = stream
    }

    func takeNext(kid: UInt64) throws -> UInt64 {
        try store.takeNextCounter(stream: stream, kid: kid)
    }
}

public final class OutgoingVoiceStream: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder: NativeOpusEncoder
    private let encryptor: SFrameEncryptor
    private let aad: Data
    private let announcement: MediaEpochAnnouncement
    private let demuxToken: Data
    private let sendPacket: @Sendable (Data) throws -> Void
    private let onPacketSent: @Sendable (Data) -> Void
    private var sequence: UInt32
    private var timestamp: UInt32
    private var first = true
    private var closed = false

    public convenience init(
        announcement: MediaEpochAnnouncement,
        demuxToken: Data,
        signalStore: KeychainSignalProtocolStore,
        counterStream: String,
        onPacketSent: @escaping @Sendable (Data) -> Void = { _ in },
        sendPacket: @escaping @Sendable (Data) throws -> Void
    ) throws {
        try self.init(
            announcement: announcement,
            demuxToken: demuxToken,
            counterStore: StreamCounterStore(store: signalStore, stream: counterStream),
            onPacketSent: onPacketSent,
            sendPacket: sendPacket
        )
    }

    public init(
        announcement: MediaEpochAnnouncement,
        demuxToken: Data,
        counterStore: SFrameCounterStore,
        onPacketSent: @escaping @Sendable (Data) -> Void = { _ in },
        sendPacket: @escaping @Sendable (Data) throws -> Void
    ) throws {
        self.announcement = announcement
        self.demuxToken = demuxToken
        self.sendPacket = sendPacket
        self.onPacketSent = onPacketSent
        self.encoder = try NativeOpusEncoder()
        self.encryptor = try SFrameEncryptor(
            kid: announcement.kid,
            baseKey: announcement.baseKey,
            counters: counterStore
        )
        self.aad = try productionSFrameAad(
            channelId: announcement.channelId,
            talkId: announcement.talkId,
            senderDemux: announcement.senderDemux
        )
        self.sequence = UInt32.random(in: UInt32.min...UInt32.max)
        self.timestamp = UInt32.random(in: UInt32.min...UInt32.max)
    }

    public func send(pcm: [Int16]) throws {
        try lock.withLock { try sendLocked(pcm: pcm, extraFlags: first ? productionMediaFlagStart : 0) }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            try? sendLocked(
                pcm: [Int16](repeating: 0, count: voiceSamplesPerFrame),
                extraFlags: productionMediaFlagEnd
            )
            closed = true
            encoder.close()
        }
    }

    deinit { close() }

    private func sendLocked(pcm: [Int16], extraFlags: UInt8) throws {
        guard !closed else { throw VoiceMediaError.closed }
        let opus = try encoder.encode(pcm)
        let sframe = try encryptor.encrypt(
            metadata: aad,
            plaintext: ProductionVoicePayload.pack(opus: opus)
        )
        let packet = try ProductionMediaDatagram.encode(
            header: ProductionMediaHeader(
                flags: extraFlags | productionMediaFlagHmac8,
                senderDemux: announcement.senderDemux,
                sequence: sequence,
                timestampRtp: timestamp,
                talkIdPrefix: productionTalkIdPrefix(announcement.talkId)
            ),
            sframe: sframe,
            demuxToken: demuxToken
        )
        try sendPacket(packet)
        onPacketSent(packet)
        first = false
        sequence &+= 1
        timestamp &+= UInt32(voiceSamplesPerFrame)
    }
}

public final class IncomingVoiceStream: @unchecked Sendable {
    private let lock = NSLock()
    public let senderAci: String
    public let senderDeviceId: Int
    public let announcement: MediaEpochAnnouncement
    private let decoder: NativeOpusDecoder
    private let jitter: NativeAdaptiveJitterBuffer
    private let decryptor: SFrameDecryptor
    private let aad: Data
    private var highestTimestamp: Int64?

    public init(
        senderAci: String,
        senderDeviceId: Int,
        announcement: MediaEpochAnnouncement
    ) throws {
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.announcement = announcement
        self.decoder = try NativeOpusDecoder()
        self.jitter = try NativeAdaptiveJitterBuffer()
        self.decryptor = SFrameDecryptor()
        try decryptor.addKey(kid: announcement.kid, baseKey: announcement.baseKey)
        self.aad = try productionSFrameAad(
            channelId: announcement.channelId,
            talkId: announcement.talkId,
            senderDemux: announcement.senderDemux
        )
    }

    public func matches(_ packet: Data) -> Bool {
        guard let received = try? ProductionMediaDatagram.decode(packet) else { return false }
        return received.header.senderDemux == announcement.senderDemux
            && received.header.talkIdPrefix == productionTalkIdPrefix(announcement.talkId)
    }

    @discardableResult
    public func accept(_ packet: Data) throws -> Bool {
        try lock.withLock {
            let received = try ProductionMediaDatagram.decode(packet)
            guard received.header.senderDemux == announcement.senderDemux,
                  received.header.talkIdPrefix == productionTalkIdPrefix(announcement.talkId) else { return false }
            let plaintext = try decryptor.decrypt(metadata: aad, frame: received.sframe)
            let opus = try ProductionVoicePayload.unpack(plaintext)
            var buffered = Data([received.header.flags])
            buffered.append(opus)
            let extended = extendTimestamp(received.header.timestampRtp)
            try jitter.push(
                sequence: received.header.sequence,
                sentTimestampMs: UInt64(extended + (1 << 32)) * 1_000 / 48_000,
                arrivalMs: DispatchTime.now().uptimeNanoseconds / 1_000_000,
                packet: buffered
            )
            if received.header.flags & productionMediaFlagEnd != 0 { try jitter.flush() }
            return true
        }
    }

    public func pop() throws -> IncomingVoicePlayout {
        try lock.withLock {
            switch try jitter.pop() {
            case .buffering:
                return .buffering
            case .missing:
                return .frame(try decoder.decode(nil), ended: false, concealed: true)
            case let .packet(packet):
                guard packet.count > 1 else { throw NativeOpusError.invalidPacket }
                let flags = packet[packet.startIndex]
                return .frame(
                    try decoder.decode(packet.dropFirst()),
                    ended: flags & productionMediaFlagEnd != 0,
                    concealed: false
                )
            }
        }
    }

    public var targetDelayMs: UInt64 { jitter.targetDelayMs }

    public func close() {
        lock.withLock {
            jitter.close()
            decoder.close()
        }
    }
    deinit { close() }

    private func extendTimestamp(_ timestamp: UInt32) -> Int64 {
        let raw = Int64(timestamp)
        guard let highestTimestamp else {
            self.highestTimestamp = raw
            return raw
        }
        let wrap = Int64(1) << 32
        let half = Int64(1) << 31
        let base = highestTimestamp & ~(wrap - 1)
        let candidate = base | raw
        let extended: Int64
        if candidate + half < highestTimestamp {
            extended = candidate + wrap
        } else if candidate > highestTimestamp + half {
            extended = candidate - wrap
        } else {
            extended = candidate
        }
        if extended > highestTimestamp { self.highestTimestamp = extended }
        return extended
    }
}

public enum IncomingVoicePlayout: Equatable, Sendable {
    case buffering
    case frame([Int16], ended: Bool, concealed: Bool)
}

public enum VoiceMediaError: Error, Equatable {
    case closed
}
