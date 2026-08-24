import Foundation
import Testing
@testable import PttTalkLib

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
