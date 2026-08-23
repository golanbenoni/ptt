import PttTalkLib
import PttWire
import SwiftUI

struct TalkView: View {
    @State private var prekey = "http://192.168.1.229:8088"
    @State private var relay = "192.168.1.229:47000"
    @State private var log = "ready\n"
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("Prekey URL", text: $prekey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("UDP host:port", text: $relay)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Talk") {
                    Button("Listen as Bob") { Task { await listen() } }
                        .disabled(busy)
                    Button("Send tone as Alice") { Task { await send() } }
                        .disabled(busy)
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
        case "bob": await listen()
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
    private func listen() async {
        guard !busy else { return }
        busy = true
        appendBoot("listen-start")
        print("PttTalk listening as Bob…")
        log.append("listening as Bob…\n")
        let pre = prekey
        let rel = relay
        do {
            let r = try await Task.detached {
                let (host, port) = try Self.parseRelay(rel)
                return try TalkClient(
                    selfAci: PttWire.bob,
                    peerAci: PttWire.alice,
                    prekeyBase: pre,
                    relayHost: host,
                    relayPort: port
                ).recvTone(timeoutMs: 120_000)
            }.value
            appendBoot("recv frames=\(r.frames) energy=\(r.energy)")
            NSLog("PttTalk recv frames=%d energy=%lld", r.frames, r.energy)
            log.append("recv frames=\(r.frames) energy=\(r.energy)\n")
        } catch {
            appendBoot("recv error: \(error)")
            NSLog("PttTalk recv error: %@", String(describing: error))
            log.append("recv error: \(error)\n")
        }
        busy = false
    }

    @MainActor
    private func send() async {
        guard !busy else { return }
        busy = true
        log.append("sending as Alice…\n")
        let pre = prekey
        let rel = relay
        do {
            let n = try await Task.detached {
                let (host, port) = try Self.parseRelay(rel)
                return try TalkClient(
                    selfAci: PttWire.alice,
                    peerAci: PttWire.bob,
                    prekeyBase: pre,
                    relayHost: host,
                    relayPort: port
                ).sendTone(durationMs: 400, paceMs: 5, bindWaitMs: 300)
            }.value
            print("PttTalk sent \(n) frames")
            log.append("sent \(n) frames\n")
        } catch {
            print("PttTalk send error: \(error)")
            log.append("send error: \(error)\n")
        }
        busy = false
    }

    nonisolated private static func parseRelay(_ rel: String) throws -> (String, UInt16) {
        let parts = rel.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw TalkError("relay must be host:port")
        }
        return (String(parts[0]), port)
    }
}
