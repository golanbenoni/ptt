import Foundation

public struct DeviceLinkInvite: Equatable, Sendable {
    public let serverUrl: String
    public let requestId: String
    public let linkCode: String

    public init(serverUrl: String, requestId: String, linkCode: String) {
        self.serverUrl = serverUrl
        self.requestId = requestId
        self.linkCode = linkCode
    }
}

public func oneTimeToken(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let queryToken = components.queryItems?
        .first(where: { $0.name == "token" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let queryToken, !queryToken.isEmpty { return queryToken }

    guard let fragment = components.fragment,
          let fragmentComponents = URLComponents(string: "ptttalk://token?\(fragment)")
    else { return nil }
    let fragmentToken = fragmentComponents.queryItems?
        .first(where: { $0.name == "token" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return fragmentToken?.isEmpty == false ? fragmentToken : nil
}

/// Builds a canonical universal link whose sensitive pairing values live in the
/// URL fragment. Fragments are not sent to the web server or included in HTTP
/// referrers, and the server-issued code remains single-use and short-lived.
public func deviceLinkInviteURL(
    serverUrl: String,
    requestId: String,
    linkCode: String
) -> URL? {
    guard validDeviceLinkServer(serverUrl),
          !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !linkCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    var payload = URLComponents()
    payload.queryItems = [
        URLQueryItem(name: "server", value: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
        URLQueryItem(name: "requestId", value: requestId.trimmingCharacters(in: .whitespacesAndNewlines)),
        URLQueryItem(name: "code", value: linkCode.trimmingCharacters(in: .whitespacesAndNewlines)),
    ]
    var result = URLComponents()
    result.scheme = "https"
    result.host = "ptttalk.app"
    result.path = "/link-device"
    result.percentEncodedFragment = payload.percentEncodedQuery
    return result.url
}

public func deviceLinkInvite(from url: URL) -> DeviceLinkInvite? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let isUniversalLink = components.scheme?.lowercased() == "https"
        && components.host?.lowercased() == "ptttalk.app"
        && components.path == "/link-device"
    let isAppLink = components.scheme?.lowercased() == "ptttalk"
        && components.host?.lowercased() == "link-device"
    guard isUniversalLink || isAppLink else { return nil }
    let encodedPayload = components.percentEncodedFragment ?? components.percentEncodedQuery
    guard let encodedPayload,
          let payload = URLComponents(string: "https://invite.invalid/?\(encodedPayload)")
    else { return nil }
    var values: [String: String] = [:]
    for item in payload.queryItems ?? [] {
        guard values[item.name] == nil else { return nil }
        values[item.name] = item.value ?? ""
    }
    let serverUrl = values["server"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    let requestId = values["requestId"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let linkCode = values["code"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard validDeviceLinkServer(serverUrl),
          (8...64).contains(requestId.count),
          (32...256).contains(linkCode.count)
    else { return nil }
    return DeviceLinkInvite(serverUrl: serverUrl, requestId: requestId, linkCode: linkCode)
}

private func validDeviceLinkServer(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
          components.scheme?.lowercased() == "https",
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else { return false }
    return components.path.isEmpty || components.path == "/"
}
