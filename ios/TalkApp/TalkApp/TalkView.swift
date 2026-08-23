import PttTalkLib
import PttWire
import SwiftUI

struct TalkView: View {
    @StateObject private var receivedAudio = ReceivedPcmPlayer()
    @State private var prekey = "http://192.168.1.229:8088"
    @State private var relay = "192.168.1.229:47000"
    @State private var log = "ready\n"
    @State private var encryption = "No encrypted tone yet."
    @State private var busy = false
    @State private var listening = false
    @State private var receiveCancellation: ReceiveCancellation?

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("Prekey URL", text: $prekey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(busy || listening)
                    TextField("UDP host:port", text: $relay)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy || listening)
                }
                Section("Talk") {
                    Button(listening ? "Stop listening" : "Listen continuously as Bob") {
                        if listening {
                            stopListening()
                        } else {
                            Task { await listenContinuously() }
                        }
                    }
                        .disabled(busy)
                    Button("Send tone as Alice") { Task { await send() } }
                        .disabled(busy || listening)
                }
                Section("Encryption") {
                    Text(encryption)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Log") {
                    Text(log)
                        .font(.system(.footnote, design: .monospaced))
                }
            }
            .navigationTitle("PTT Talk")
            .task {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dump = (
                    ["args:"] + CommandLine.arguments + [
                        "PTT_ROLE=" + (ProcessInfo.processInfo.environment["PTT_ROLE"] ?? "-"),
                    ]
                ).joined(separator: "\n")
                try? dump.write(
                    to: docs.appendingPathComponent("boot.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                await autoStartFromEnv()
            }
        }
    }

    @MainActor
    private func autoStartFromEnv() async {
        let env = ProcessInfo.processInfo.environment
        let args = Array(CommandLine.arguments.dropFirst())
        func flag(_ name: String) -> String? {
            if let v = env[name], !v.isEmpty { return v }
            if let idx = args.firstIndex(of: "--\(name.lowercased().replacingOccurrences(of: "_", with: "-"))"),
               idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }
        if let p = flag("PTT_PREKEY") { prekey = p }
        if let r = flag("PTT_RELAY") { relay = r }
        switch flag("PTT_ROLE") {
        case "bob": await listenContinuously()
        case "alice":
            try? await Task.sleep(for: .milliseconds(1500))
            await send()
        default: break
        }
    }

    private func appendBoot(_ line: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boot.txt")
        let prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (prev + "\n" + line).write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func listenContinuously() async {
        guard !busy, !listening else { return }
        let endpoint: (prekey: String, host: String, port: UInt16)
        do {
            endpoint = try Self.parseEndpoints(prekey: prekey, relay: relay)
        } catch {
            log.append("listen error: \(error)\n")
            return
        }
        let cancellation = ReceiveCancellation()
        receiveCancellation = cancellation
        listening = true
        appendBoot("listen-start")
        var receivedCount = 0

        while !cancellation.isCancelled {
            print("PttTalk listening as Bob…")
            log.append(receivedCount == 0 ? "listening as Bob…\n" : "listener rearmed\n")
            do {
                let r = try await Task.detached {
                    return try TalkClient(
                        selfAci: PttWire.bob,
                        peerAci: PttWire.alice,
                        prekeyBase: endpoint.prekey,
                        relayHost: endpoint.host,
                        relayPort: endpoint.port
                    ).recvTone(timeoutMs: 120_000) {
                        !cancellation.isCancelled
                    }
                }.value
                if cancellation.isCancelled { break }
                guard r.frames > 0 else { continue }

                receivedCount += 1
                if let diagnostics = r.encryption {
                    encryption = Self.formatEncryption(diagnostics, role: "receiver (Bob)")
                }
                appendBoot("recv #\(receivedCount) frames=\(r.frames) energy=\(r.energy)")
                NSLog("PttTalk recv #%d frames=%d energy=%lld", receivedCount, r.frames, r.energy)
                log.append("recv #\(receivedCount) frames=\(r.frames) energy=\(r.energy)\n")
                do {
                    try receivedAudio.play(r.pcm)
                    appendBoot("playback #\(receivedCount) scheduled")
                    log.append("playing received tone #\(receivedCount)\n")
                } catch {
                    appendBoot("playback #\(receivedCount) error: \(error)")
                    NSLog("PttTalk playback error: %@", String(describing: error))
                    log.append("playback error: \(error.localizedDescription)\n")
                }
            } catch {
                if cancellation.isCancelled { break }
                appendBoot("recv error: \(error)")
                NSLog("PttTalk recv error: %@", String(describing: error))
                log.append("recv error: \(error)\nrearming listener…\n")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if receiveCancellation === cancellation {
            receiveCancellation = nil
            listening = false
            log.append("listener stopped\n")
        }
    }

    @MainActor
    private func stopListening() {
        receiveCancellation?.cancel()
        log.append("stopping listener…\n")
    }

    @MainActor
    private func send() async {
        guard !busy else { return }
        let endpoint: (prekey: String, host: String, port: UInt16)
        do {
            endpoint = try Self.parseEndpoints(prekey: prekey, relay: relay)
        } catch {
            log.append("send error: \(error)\n")
            return
        }
        busy = true
        log.append("sending as Alice…\n")
        do {
            let result = try await Task.detached {
                return try TalkClient(
                    selfAci: PttWire.alice,
                    peerAci: PttWire.bob,
                    prekeyBase: endpoint.prekey,
                    relayHost: endpoint.host,
                    relayPort: endpoint.port
                ).sendToneDetailed(durationMs: 400, paceMs: 5, bindWaitMs: 300)
            }.value
            encryption = Self.formatEncryption(result.encryption, role: "sender (Alice)")
            print("PttTalk sent \(result.frames) frames")
            log.append("sent \(result.frames) encrypted frames\n")
        } catch {
            print("PttTalk send error: \(error)")
            log.append("send error: \(error)\n")
        }
        busy = false
    }

    private static func formatEncryption(_ value: EncryptionDiagnostics, role: String) -> String {
        [
            "side: \(role)",
            "key setup: \(value.keyEstablishment)",
            "media: \(value.algorithm)",
            "channel: \(value.channel.uuidString.lowercased())",
            "talk: \(value.talkId.uuidString.lowercased())",
            "sender: \(value.senderAci.uuidString.lowercased())",
            "receiver: \(value.receiverAci.uuidString.lowercased())",
            "demux: \(value.demux)  frames: \(value.frameCount)",
            "wrapped key: \(value.wrappedKeyBytes) bytes",
            "key fp: sha256:\(value.mediaKeyFingerprint)",
            "AAD fp: sha256:\(value.aadFingerprint)",
        ].joined(separator: "\n")
    }

    nonisolated private static func parseEndpoints(
        prekey: String,
        relay: String
    ) throws -> (prekey: String, host: String, port: UInt16) {
        guard let prekeyURL = URL(string: prekey),
              ["http", "https"].contains(prekeyURL.scheme?.lowercased()),
              prekeyURL.host != nil else {
            throw TalkError("prekey must be an HTTP(S) URL")
        }
        let parts = relay.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw TalkError("relay must be host:port")
        }
        return (prekey, String(parts[0]), port)
    }
}

private final class ReceiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
