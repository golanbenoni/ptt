import Foundation

public struct TalkError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

func pttTrace(_ message: String) {
    NSLog("PttTalk %@", message)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ptt-trace.log")
    let line = Data((message + "\n").utf8)
    if FileManager.default.fileExists(atPath: url.path) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(line)
        }
    } else {
        try? line.write(to: url)
    }
}

public enum Flags {
    public static func value(_ args: [String], _ name: String, default defaultValue: String) -> String {
        if let idx = args.firstIndex(of: name), idx + 1 < args.count {
            return args[idx + 1]
        }
        return defaultValue
    }
}
