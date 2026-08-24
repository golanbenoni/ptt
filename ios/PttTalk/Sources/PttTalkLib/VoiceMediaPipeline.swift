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
    private var sequence: UInt32
    private var timestamp: UInt32
    private var first = true
    private var closed = false

    public init(
        announcement: MediaEpochAnnouncement,
        demuxToken: Data,
        signalStore: KeychainSignalProtocolStore,
        counterStream: String,
        sendPacket: @escaping @Sendable (Data) throws -> Void
    ) throws {
        self.announcement = announcement
        self.demuxToken = demuxToken
        self.sendPacket = sendPacket
        self.encoder = try NativeOpusEncoder()
        self.encryptor = try SFrameEncryptor(
            kid: announcement.kid,
            baseKey: announcement.baseKey,
            counters: StreamCounterStore(store: signalStore, stream: counterStream)
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
    private let decryptor: SFrameDecryptor
    private let aad: Data

    public init(
        senderAci: String,
        senderDeviceId: Int,
        announcement: MediaEpochAnnouncement
    ) throws {
        self.senderAci = senderAci
        self.senderDeviceId = senderDeviceId
        self.announcement = announcement
        self.decoder = try NativeOpusDecoder()
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

    public func accept(_ packet: Data) throws -> [Int16]? {
        try lock.withLock {
            let received = try ProductionMediaDatagram.decode(packet)
            guard received.header.senderDemux == announcement.senderDemux,
                  received.header.talkIdPrefix == productionTalkIdPrefix(announcement.talkId) else { return nil }
            let plaintext = try decryptor.decrypt(metadata: aad, frame: received.sframe)
            let opus = try ProductionVoicePayload.unpack(plaintext)
            return try decoder.decode(opus)
        }
    }

    public func concealLoss() throws -> [Int16] { try lock.withLock { try decoder.decode(nil) } }
    public func close() { lock.withLock { decoder.close() } }
    deinit { close() }
}

public enum VoiceMediaError: Error, Equatable {
    case closed
}
