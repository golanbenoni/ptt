import Foundation

public enum CallEventTransportError: Error, Equatable {
    case invalidServerUrl
    case insecureServerUrl
}

/// Builds the fixed device-authenticated call coordination endpoint without
/// retaining unrelated path, query, or fragment state from configuration.
public func callEventWebSocketUrl(
    serverUrl: String,
    allowPlaintext: Bool = false
) throws -> URL {
    let normalized = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: normalized),
          let scheme = components.scheme?.lowercased(),
          components.host != nil,
          scheme == "https" || scheme == "http" else {
        throw CallEventTransportError.invalidServerUrl
    }
    guard scheme == "https" || allowPlaintext else {
        throw CallEventTransportError.insecureServerUrl
    }
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.path = "/v1/calls/events"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
        throw CallEventTransportError.invalidServerUrl
    }
    return url
}
