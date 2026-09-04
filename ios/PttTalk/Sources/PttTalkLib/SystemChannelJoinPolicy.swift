import Foundation

public enum SystemChannelJoinDecision: Equatable, Sendable {
    case alreadyActive
    case requestJoin
    case replaceActive(UUID)
}

public enum SystemChannelJoinPolicy {
    public static func decision(activeChannelId: UUID?, requestedChannelId: UUID) -> SystemChannelJoinDecision {
        guard let activeChannelId else { return .requestJoin }
        if activeChannelId == requestedChannelId { return .alreadyActive }
        return .replaceActive(activeChannelId)
    }
}
