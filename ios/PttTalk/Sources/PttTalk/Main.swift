import Darwin
import Foundation
import PttTalkLib
import PttWire

@main
enum PttTalkMain {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            fputs("usage: PttTalk send|recv [--prekey URL] [--relay host:port] [--ms N] [--out wav]\n", stderr)
            exit(2)
        }
        args.removeFirst()
        let prekey = Flags.value(args, "--prekey", default: "http://127.0.0.1:8088")
        let relay = Flags.value(args, "--relay", default: "127.0.0.1:47000")
        let parts = relay.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw TalkError("relay must be host:port")
        }
        let host = String(parts[0])
        switch cmd {
        case "send":
            let client = TalkClient(
                selfAci: PttWire.alice,
                peerAci: PttWire.bob,
                prekeyBase: prekey,
                relayHost: host,
                relayPort: port
            )
            let n = try client.sendTone(
                durationMs: Int(Flags.value(args, "--ms", default: "800")) ?? 800,
                paceMs: Int(Flags.value(args, "--pace-ms", default: "0")) ?? 0,
                bindWaitMs: Int(Flags.value(args, "--bind-wait-ms", default: "250")) ?? 250
            )
            print("sent \(n) frames")
        case "recv":
            let out = URL(fileURLWithPath: Flags.value(args, "--out", default: "/tmp/ptt-bob.wav"))
            let client = TalkClient(
                selfAci: PttWire.bob,
                peerAci: PttWire.alice,
                prekeyBase: prekey,
                relayHost: host,
                relayPort: port
            )
            let r = try client.recvTone(outWav: out)
            print("recv frames=\(r.frames) energy=\(r.energy) wav=\(out.path)")
            if r.energy <= 50_000 {
                throw TalkError("silence energy=\(r.energy)")
            }
        default:
            throw TalkError("unknown \(cmd)")
        }
    }
}
