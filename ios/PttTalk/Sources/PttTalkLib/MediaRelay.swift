import Foundation
import PttWire

public protocol MediaRelay: AnyObject, Sendable {
    func send(_ packet: Data) throws
    func close()
}

/// Device-authenticated, ciphertext-only media tunnel over WebSocket TLS.
public final class TlsMediaRelay: NSObject, MediaRelay, URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let request: URLRequest
    private let onMedia: @Sendable (Data) -> Void
    private let onError: @Sendable (Error) -> Void
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var socket: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var pendingSend: Task<Void, Never>?
    private var opened = false
    private var closed = false

    private init(
        request: URLRequest,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.request = request
        self.onMedia = onMedia
        self.onError = onError
    }

    public static func connect(
        serverUrl: String,
        accessToken: String,
        channelId: UUID,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) async throws -> TlsMediaRelay {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 4_096 else {
            throw TlsMediaRelayError.invalidDeviceToken
        }
        var request = URLRequest(url: try tlsMediaWebSocketUrl(serverUrl: serverUrl, channelId: channelId))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let relay = TlsMediaRelay(request: request, onMedia: onMedia, onError: onError)
        try await relay.open()
        return relay
    }

    public func send(_ packet: Data) throws {
        guard packet.count == productionMediaDatagramBytes else {
            throw TlsMediaRelayError.invalidMediaLength
        }
        try lock.withLock {
            guard !closed, opened, let socket else { throw TlsMediaRelayError.closed }
            let previous = pendingSend
            pendingSend = Task { [weak self] in
                _ = await previous?.result
                guard !Task.isCancelled else { return }
                do { try await socket.send(.data(packet)) }
                catch { self?.fail(error) }
            }
        }
    }

    public func close() {
        let state = lock.withLock { () -> (URLSessionWebSocketTask?, CheckedContinuation<Void, Error>?) in
            guard !closed else { return (nil, nil) }
            closed = true
            opened = false
            receiveTask?.cancel()
            pendingSend?.cancel()
            let continuation = opening
            opening = nil
            return (socket, continuation)
        }
        state.1?.resume(throwing: TlsMediaRelayError.closed)
        state.0?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !closed else { return nil }
            opened = true
            let value = opening
            opening = nil
            return value
        }
        continuation?.resume()
        startReceiving(webSocketTask)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        fail(error)
    }

    private func open() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let task = lock.withLock { () -> URLSessionWebSocketTask? in
                guard !closed, socket == nil else { return nil }
                opening = continuation
                let value = session.webSocketTask(with: request)
                socket = value
                return value
            }
            guard let task else {
                continuation.resume(throwing: TlsMediaRelayError.closed)
                return
            }
            task.resume()
        }
    }

    private func startReceiving(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case let .data(packet) = message,
                          packet.count == productionMediaDatagramBytes else {
                        throw TlsMediaRelayError.invalidMediaLength
                    }
                    self?.onMedia(packet)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let value = opening
            opening = nil
            return value
        }
        continuation?.resume(throwing: error)
        if continuation == nil, !lock.withLock({ closed }) { onError(error) }
    }

    deinit { close() }
}

public final class AdaptiveMediaRelay: MediaRelay, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MediaRelay
    private let serverUrl: String
    private let accessToken: String
    private let channelId: UUID
    private let onMedia: @Sendable (Data) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onTransportChanged: @Sendable (String) -> Void
    private var closed = false
    private var switchingToTls = false

    private init(
        initial: MediaRelay,
        serverUrl: String,
        accessToken: String,
        channelId: UUID,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onTransportChanged: @escaping @Sendable (String) -> Void
    ) {
        current = initial
        self.serverUrl = serverUrl
        self.accessToken = accessToken
        self.channelId = channelId
        self.onMedia = onMedia
        self.onError = onError
        self.onTransportChanged = onTransportChanged
    }

    public static func connect(
        serverUrl: String,
        accessToken: String,
        channelId: UUID,
        publicAddress: String,
        ticket: String,
        expectedSenderDemux: UInt32,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in },
        onTransportChanged: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AdaptiveMediaRelay {
        let holder = WeakAdaptiveHolder()
        do {
            let udp = try AuthenticatedUdpRelay.connect(
                publicAddress: publicAddress,
                ticket: ticket,
                expectedSenderDemux: expectedSenderDemux,
                onMedia: onMedia,
                onError: { error in
                    guard let adaptive = holder.value else { return onError(error) }
                    Task { await adaptive.switchToTls(after: error) }
                }
            )
            let result = AdaptiveMediaRelay(
                initial: udp,
                serverUrl: serverUrl,
                accessToken: accessToken,
                channelId: channelId,
                onMedia: onMedia,
                onError: onError,
                onTransportChanged: onTransportChanged
            )
            holder.value = result
            return result
        } catch {
            let fallback = try await TlsMediaRelay.connect(
                serverUrl: serverUrl,
                accessToken: accessToken,
                channelId: channelId,
                onMedia: onMedia,
                onError: onError
            )
            onTransportChanged("UDP unavailable; encrypted media is using TLS.")
            return AdaptiveMediaRelay(
                initial: fallback,
                serverUrl: serverUrl,
                accessToken: accessToken,
                channelId: channelId,
                onMedia: onMedia,
                onError: onError,
                onTransportChanged: onTransportChanged
            )
        }
    }

    public func send(_ packet: Data) throws {
        do {
            try lock.withLock {
                guard !closed else { throw TlsMediaRelayError.closed }
                try current.send(packet)
            }
        } catch {
            let shouldFallback = lock.withLock { !closed && !(current is TlsMediaRelay) }
            if shouldFallback { Task { await switchToTls(after: error) } }
            throw error
        }
    }

    public func close() {
        let relay = lock.withLock { () -> MediaRelay? in
            guard !closed else { return nil }
            closed = true
            return current
        }
        relay?.close()
    }

    private func switchToTls(after udpError: Error) async {
        let shouldSwitch = lock.withLock { () -> Bool in
            guard !closed, !(current is TlsMediaRelay), !switchingToTls else { return false }
            switchingToTls = true
            return true
        }
        guard shouldSwitch else { return }
        defer { lock.withLock { switchingToTls = false } }
        do {
            let fallback = try await TlsMediaRelay.connect(
                serverUrl: serverUrl,
                accessToken: accessToken,
                channelId: channelId,
                onMedia: onMedia,
                onError: onError
            )
            let previous = lock.withLock { () -> MediaRelay? in
                guard !closed, !(current is TlsMediaRelay) else { return nil }
                let value = current
                current = fallback
                return value
            }
            guard let previous else { fallback.close(); return }
            previous.close()
            onTransportChanged("UDP unavailable; encrypted media switched to TLS.")
        } catch {
            onError(TlsMediaRelayError.fallbackFailed(udp: udpError, tls: error))
        }
    }

    deinit { close() }
}

private final class WeakAdaptiveHolder: @unchecked Sendable {
    weak var value: AdaptiveMediaRelay?
}

public func tlsMediaWebSocketUrl(serverUrl: String, channelId: UUID) throws -> URL {
    let normalized = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased(),
          components.host != nil, ["https", "http"].contains(scheme) else {
        throw TlsMediaRelayError.invalidServerUrl
    }
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.path = "/v1/media/tunnel"
    components.queryItems = [URLQueryItem(name: "channelId", value: channelId.uuidString.lowercased())]
    components.fragment = nil
    guard let url = components.url else { throw TlsMediaRelayError.invalidServerUrl }
    return url
}

public enum TlsMediaRelayError: Error {
    case invalidServerUrl
    case invalidDeviceToken
    case invalidMediaLength
    case closed
    case fallbackFailed(udp: Error, tls: Error)
}
