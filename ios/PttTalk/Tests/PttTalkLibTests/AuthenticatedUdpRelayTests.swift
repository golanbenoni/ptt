import Foundation
import Testing
@testable import PttTalkLib

@Test func tlsMediaEndpointUsesWebSocketTlsAndCanonicalChannelQuery() throws {
    let channel = UUID(uuidString: "54b86f25-447f-4abc-a885-7c2e6b2c109c")!
    #expect(
        try tlsMediaWebSocketUrl(
            serverUrl: "https://ptt.example.test/ignored?secret=no",
            channelId: channel
        ).absoluteString
            == "wss://ptt.example.test/v1/media/tunnel?channelId=54b86f25-447f-4abc-a885-7c2e6b2c109c"
    )
    #expect(
        try tlsMediaWebSocketUrl(serverUrl: "http://127.0.0.1:8080", channelId: channel).scheme == "ws"
    )
}

@Test func relayEndpointAcceptsHostnamesIpv4AndIpv6() throws {
    #expect(try parseRelayEndpoint("relay.example:47000") == RelayEndpoint(host: "relay.example", port: 47_000))
    #expect(try parseRelayEndpoint("udp://127.0.0.1:9") == RelayEndpoint(host: "127.0.0.1", port: 9))
    #expect(try parseRelayEndpoint("udp://[::1]:65535") == RelayEndpoint(host: "::1", port: 65_535))
}

@Test func relayEndpointRejectsAmbiguity() {
    for value in ["", "127.0.0.1", "tcp://127.0.0.1:9", "udp://:9", "udp://host:0"] {
        #expect(throws: AuthenticatedRelayError.invalidAddress) {
            try parseRelayEndpoint(value)
        }
    }
}
