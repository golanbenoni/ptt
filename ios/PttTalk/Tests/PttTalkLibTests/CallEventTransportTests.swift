import Foundation
import Testing
@testable import PttTalkLib

@Test func callEventEndpointIsTlsAndCanonical() throws {
    #expect(
        try callEventWebSocketUrl(
            serverUrl: "https://ptttalk.app/ignored/path?token=unsafe#fragment"
        ).absoluteString == "wss://ptttalk.app/v1/calls/events"
    )
    #expect(
        try callEventWebSocketUrl(
            serverUrl: "https://calls.example.test:8443"
        ).absoluteString == "wss://calls.example.test:8443/v1/calls/events"
    )
}

@Test func callEventEndpointAllowsPlaintextOnlyWhenExplicitlyEnabled() throws {
    #expect(throws: CallEventTransportError.insecureServerUrl) {
        try callEventWebSocketUrl(serverUrl: "http://127.0.0.1:8080/base")
    }
    #expect(
        try callEventWebSocketUrl(
            serverUrl: "http://127.0.0.1:8080/base",
            allowPlaintext: true
        ).absoluteString == "ws://127.0.0.1:8080/v1/calls/events"
    )
    #expect(throws: CallEventTransportError.invalidServerUrl) {
        try callEventWebSocketUrl(serverUrl: "not a URL", allowPlaintext: true)
    }
}
