import Foundation
import PttWire

public struct TalkResult: Sendable {
    public var pcm: Data
    public var frames: Int
    public var energy: Int64
}

public final class TalkClient: @unchecked Sendable {
    public let selfAci: UUID
    public let peerAci: UUID
    public let prekeyBase: String
    public let relayHost: String
    public let relayPort: UInt16
    public let channel: UUID

    public init(
        selfAci: UUID,
        peerAci: UUID,
        prekeyBase: String,
        relayHost: String,
        relayPort: UInt16,
        channel: UUID = PttWire.channel
    ) {
        self.selfAci = selfAci
        self.peerAci = peerAci
        self.prekeyBase = prekeyBase.hasSuffix("/") ? String(prekeyBase.dropLast()) : prekeyBase
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.channel = channel
    }

    public func sendTone(durationMs: Int = 800, paceMs: Int = 0, bindWaitMs: Int = 80) throws -> Int {
        let crypto = try TalkCrypto(aci: selfAci)
        try putBundle(crypto)
        let peerBundle = try waitForPeerBundle()
        try crypto.process(peer: peerAci, bundle: peerBundle)

        let frames = UInt32(durationMs / Pcm.frameMs)
        let talkId = UUID()
        let demux: UInt32 = 1
        let mediaKey = AesGcmFrames.newKey()
        let wrapped = try crypto.encrypt1to1(peer: peerAci, plaintext: mediaKey)
        let aad = PttWire.aad(channel: channel, talk: talkId, demux: demux)

        let sock = try UdpSocket()
        try sock.connect(host: relayHost, port: relayPort)
        try sock.send(PttWire.bindPacket(channel: channel, aci: selfAci), host: relayHost, port: relayPort)
        Thread.sleep(forTimeInterval: Double(bindWaitMs) / 1000.0)
        try sock.send(
            PttWire.keyPacket(
                channel: channel,
                talk: talkId,
                demux: demux,
                frames: frames,
                wrappedKey: wrapped
            ),
            host: relayHost,
            port: relayPort
        )
        for i in 0..<Int(frames) {
            let payload = try AesGcmFrames.encrypt(
                key: mediaKey,
                counter: UInt64(i),
                aad: aad,
                plaintext: Pcm.sineFrame(index: i)
            )
            try sock.send(
                PttWire.framePacket(channel: channel, talk: talkId, demux: demux, payload: payload),
                host: relayHost,
                port: relayPort
            )
            if paceMs > 0 { Thread.sleep(forTimeInterval: Double(paceMs) / 1000.0) }
        }
        return Int(frames)
    }

    public func recvTone(outWav: URL? = nil, timeoutMs: Int = 15_000) throws -> TalkResult {
        let crypto = try TalkCrypto(aci: selfAci)
        try putBundle(crypto)
        let sock = try UdpSocket()
        try sock.connect(host: relayHost, port: relayPort)
        try sock.send(PttWire.bindPacket(channel: channel, aci: selfAci), host: relayHost, port: relayPort)
        // Recipient does not process the talker's bundle: the KEY packet is a
        // PreKeySignalMessage that creates the session. Announce before Alice PUTs
        // so the LAN orchestrator cannot deadlock.
        pttTrace("listening aci=\(selfAci.uuidString.lowercased())")

        var talkId: UUID?
        var demux: UInt32 = 0
        var expected: Int = 0
        var mediaKey: Data?
        var pcm = Data()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let remain = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            guard let data = try sock.receive(timeoutMs: min(remain, 250)), !data.isEmpty else {
                continue
            }
            pttTrace("pkt type=\(PttWire.packetType(data)) n=\(data.count)")
            switch PttWire.packetType(data) {
            case PttWire.key:
                talkId = PttWire.packetTalkId(data)
                demux = PttWire.packetDemux(data)
                expected = Int(PttWire.packetKeyFrameCount(data))
                mediaKey = try crypto.decrypt1to1(sender: peerAci, ciphertext: PttWire.packetKeyWrapped(data))
            case PttWire.frame:
                guard let key = mediaKey, let tid = talkId else { continue }
                let aad = PttWire.aad(channel: channel, talk: tid, demux: demux)
                pcm.append(try AesGcmFrames.decrypt(key: key, aad: aad, packet: PttWire.packetFramePayload(data)))
            default:
                continue
            }
            if expected > 0 && pcm.count >= expected * Pcm.frameBytes { break }
        }
        if let outWav {
            try FileManager.default.createDirectory(
                at: outWav.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Pcm.writeWav(pcm, to: outWav)
        }
        return TalkResult(pcm: pcm, frames: pcm.count / Pcm.frameBytes, energy: Pcm.energy(pcm))
    }

    private func putBundle(_ crypto: TalkCrypto) throws {
        let json = try BundleJson.encode(crypto.localBundle())
        let url = URL(string: "\(prekeyBase)/v1/prekeys/\(crypto.aci.uuidString.lowercased())")!
        let (status, _) = try PttHttp.request(method: "PUT", url: url, body: json)
        guard (200...299).contains(status) else { throw TalkError("put prekeys \(status)") }
    }

    /// First successful GET consumes the OTPK on the server; keep that body.
    private func waitForPeerBundle() throws -> PreKeyBundleJson {
        let deadline = Date().addingTimeInterval(8)
        let url = URL(string: "\(prekeyBase)/v1/prekeys/\(peerAci.uuidString.lowercased())")!
        while Date() < deadline {
            let (status, body) = try PttHttp.request(method: "GET", url: url)
            if status == 200 { return try BundleJson.decode(body) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TalkError("peer \(peerAci) never registered")
    }
}
