import Foundation
import Testing
@testable import PttTalkLib

@Test func relayExpiryParserAcceptsServerFractionalAndWholeSeconds() {
    #expect(parseIso8601Date("2026-08-23T21:52:47.123456Z") != nil)
    #expect(parseIso8601Date("2026-08-23T21:52:47Z") != nil)
    #expect(parseIso8601Date("not-a-date") == nil)
}

@Test func base64UrlRoundTripAndRejectsMalformedInput() throws {
    let bytes = Data([0xfb, 0xff, 0, 1, 2])
    #expect(bytes.base64Url == "-_8AAQI")
    #expect(try Data(base64Url: bytes.base64Url) == bytes)
    #expect(throws: ControlApiError.invalidBase64Url) { try Data(base64Url: "***") }
}

@Test func controlApiRequiresTlsUnlessExplicitlyEnabled() throws {
    #expect(throws: ControlApiError.insecureServerUrl) {
        try ControlApi(serverUrl: "http://127.0.0.1:8080")
    }
    let local = try ControlApi(serverUrl: "http://127.0.0.1:8080/", allowInsecureHttp: true)
    #expect(local.baseUrl.absoluteString == "http://127.0.0.1:8080")
    _ = try ControlApi(serverUrl: "https://ptt.example.test")
}

@Test func randomRequestTokenIsExactlySixteenBytes() throws {
    let token = Data.random(count: 16)
    #expect(token.count == 16)
    #expect(try Data(base64Url: token.base64Url).count == 16)
}

@Test func enrollmentDeepLinksAcceptQueryAndFragmentTokens() throws {
    #expect(oneTimeToken(from: try #require(URL(string: "ptttalk://enroll?token=query-token"))) == "query-token")
    #expect(oneTimeToken(from: try #require(URL(string: "https://ptt.example.test/enroll#token=fragment-token"))) == "fragment-token")
    #expect(oneTimeToken(from: try #require(URL(string: "ptttalk://enroll?next=home"))) == nil)
    #expect(oneTimeToken(from: try #require(URL(string: "ptttalk://enroll#token="))) == nil)
}

@Test func pushRegistrationRejectsUnsupportedProvidersAndMalformedTokens() async throws {
    let api = try ControlApi(serverUrl: "https://ptt.example.test")
    let session = DeviceSession(
        serverUrl: "https://ptt.example.test",
        aci: UUID().uuidString,
        deviceId: 1,
        mailboxId: UUID().uuidString,
        accessToken: "fixture"
    )
    for (provider, token) in [
        ("web-push", Data(repeating: 1, count: 32)),
        ("apns-ptt", Data(repeating: 1, count: 15)),
        ("apns", Data(repeating: 1, count: 4_097)),
    ] {
        do {
            try await api.registerPush(session: session, provider: provider, token: token)
            Issue.record("Invalid push registration was accepted")
        } catch {
            #expect(error as? ControlApiError == .invalidRequest)
        }
    }
}

@Test func presenceRejectsUnsupportedModeBeforeNetworkUse() async throws {
    let api = try ControlApi(serverUrl: "https://ptt.example.test")
    let session = DeviceSession(
        serverUrl: "https://ptt.example.test",
        aci: UUID().uuidString,
        deviceId: 1,
        mailboxId: UUID().uuidString,
        accessToken: "fixture"
    )
    do {
        try await api.setPresence(session: session, mode: "invisible")
        Issue.record("Invalid presence mode was accepted")
    } catch {
        #expect(error as? ControlApiError == .invalidRequest)
    }
}
