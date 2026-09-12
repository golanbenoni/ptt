import Foundation

/// Bounds authorization-critical roster and call-key queue operations so a single stalled
/// control request cannot consume the complete answer-to-audio budget. Cached authenticated
/// state is usable only during the documented five-second network-transition window.
public enum CallCoordinationTimingPolicy {
    public static let maximumNetworkWait: TimeInterval = 0.250
    public static let maximumAuthenticatedStateAge: TimeInterval = 5
    public static let retryDelay: Duration = .milliseconds(25)
    public static let maximumIdempotentSendAttempts = 2

    public static func mayRetry(
        _ error: Error,
        lastAuthenticatedAt: Date,
        now: Date = Date()
    ) -> Bool {
        let age = now.timeIntervalSince(lastAuthenticatedAt)
        return age >= 0 && age <= maximumAuthenticatedStateAge && isTransient(error)
    }

    public static func mayRetryIdempotentSend(
        _ error: Error,
        completedAttempts: Int
    ) -> Bool {
        completedAttempts < maximumIdempotentSendAttempts && isTransient(error)
    }

    public static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed, .secureConnectionFailed,
                 .cannotLoadFromNetwork, .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        if case let ControlApiError.server(status, _) = error {
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        }
        return false
    }
}
