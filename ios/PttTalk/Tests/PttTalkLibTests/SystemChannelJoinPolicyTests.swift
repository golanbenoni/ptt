import Foundation
import Testing
@testable import PttTalkLib

@Test func systemChannelJoinRequestsAnInitialChannel() {
    let requested = UUID()
    #expect(SystemChannelJoinPolicy.decision(activeChannelId: nil, requestedChannelId: requested) == .requestJoin)
}

@Test func systemChannelJoinIsIdempotentForTheActiveChannel() {
    let channel = UUID()
    #expect(SystemChannelJoinPolicy.decision(activeChannelId: channel, requestedChannelId: channel) == .alreadyActive)
}

@Test func systemChannelJoinReplacesAStaleActiveChannel() {
    let active = UUID()
    let requested = UUID()
    #expect(SystemChannelJoinPolicy.decision(activeChannelId: active, requestedChannelId: requested) == .replaceActive(active))
}
