import Foundation

public enum CallTimelineEventKind: String, Sendable {
    case started
    case answered
    case participantsChanged = "participants_changed"
    case ended
}

/// A structured call event carried inside the existing pairwise-encrypted chat
/// envelope. The relay only sees ciphertext and normal conversation retention
/// and device-linking rules apply.
public struct EncryptedCallTimelineEvent: Equatable, Sendable {
    public let callId: UUID
    public let kind: CallTimelineEventKind
    public let startedAt: Date
    public let durationMs: Int64
    public let participantCount: Int
    public let endReason: String

    public init(
        callId: UUID, kind: CallTimelineEventKind, startedAt: Date,
        durationMs: Int64 = 0, participantCount: Int, endReason: String = ""
    ) {
        self.callId = callId
        self.kind = kind
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.participantCount = participantCount
        self.endReason = endReason
    }
}

public struct EncryptedCallHistoryItem: Equatable, Identifiable, Sendable {
    public let callId: UUID
    public let channelId: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let durationMs: Int64
    public let participantCount: Int
    public let endReason: String
    public let outgoing: Bool
    public let answeredOnThisAccount: Bool
    public var id: UUID { callId }
    public var missed: Bool { endReason == "missed" && !answeredOnThisAccount }
}

public enum EncryptedCallTimelineCodec {
    private static let prefix = "ptt-call-event:v1"
    private static let maximumDurationMs: Int64 = 8 * 60 * 60 * 1_000

    public static func encode(_ event: EncryptedCallTimelineEvent) throws -> String {
        try validate(event)
        return [
            prefix,
            event.kind.rawValue,
            event.callId.uuidString.lowercased(),
            String(Int64((event.startedAt.timeIntervalSince1970 * 1_000).rounded())),
            String(event.durationMs),
            String(event.participantCount),
            event.endReason.isEmpty ? "-" : event.endReason,
        ].joined(separator: "|")
    }

    public static func decode(_ value: String) throws -> EncryptedCallTimelineEvent? {
        guard value.hasPrefix("\(prefix)|") else { return nil }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, fields[0] == prefix,
              let kind = CallTimelineEventKind(rawValue: fields[1]),
              let callId = UUID(uuidString: fields[2]),
              callId.uuidString.lowercased() == fields[2],
              let timestamp = Int64(fields[3]),
              let duration = Int64(fields[4]),
              let participantCount = Int(fields[5]) else {
            throw EncryptedChatError.invalidMessage
        }
        let event = EncryptedCallTimelineEvent(
            callId: callId, kind: kind,
            startedAt: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000),
            durationMs: duration, participantCount: participantCount,
            endReason: fields[6] == "-" ? "" : fields[6]
        )
        try validate(event)
        return event
    }

    public static func history(messages: [ChatMessage], localAci: String) -> [EncryptedCallHistoryItem] {
        let decoded: [(ChatMessage, EncryptedCallTimelineEvent)] = messages.compactMap { message in
            do {
                guard let event = try decode(message.text) else { return nil }
                return (message, event)
            } catch {
                return nil
            }
        }
        return Dictionary(grouping: decoded, by: { $0.1.callId }).compactMap { callId, entries in
            let ordered = entries.sorted { $0.0.sentAt < $1.0.sentAt }
            guard let first = ordered.first, let latest = ordered.last else { return nil }
            let started = ordered.first(where: { $0.1.kind == .started }) ?? first
            let ended = ordered.last(where: { $0.1.kind == .ended })
            return EncryptedCallHistoryItem(
                callId: callId, channelId: latest.0.channelId,
                startedAt: started.1.startedAt, endedAt: ended?.0.sentAt,
                durationMs: ended?.1.durationMs ?? latest.1.durationMs,
                participantCount: ordered.map { $0.1.participantCount }.max() ?? 1,
                endReason: ended?.1.endReason ?? "",
                outgoing: started.0.senderAci.caseInsensitiveCompare(localAci) == .orderedSame,
                answeredOnThisAccount: ordered.contains {
                    $0.1.kind == .answered && $0.0.senderAci.caseInsensitiveCompare(localAci) == .orderedSame
                }
            )
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private static func validate(_ event: EncryptedCallTimelineEvent) throws {
        let reason = try! NSRegularExpression(pattern: "^[a-z0-9_]{0,32}$")
        let range = NSRange(event.endReason.startIndex..., in: event.endReason)
        guard event.startedAt.timeIntervalSince1970 >= 0,
              (0...maximumDurationMs).contains(event.durationMs),
              (1...8).contains(event.participantCount),
              reason.firstMatch(in: event.endReason, range: range) != nil,
              event.kind == .ended || event.endReason.isEmpty else {
            throw EncryptedChatError.invalidMessage
        }
    }
}
