import Foundation
import PttWire

public protocol MediaRelay: AnyObject, Sendable {
    func send(_ packet: Data) throws
    func flush() async throws
    func close()
}

public extension MediaRelay {
    func flush() async throws {}
}

public enum MediaRelayConnectionState: Equatable, Sendable {
    case reconnecting(attempt: Int)
    case connected(transport: String)
    case unavailable
}

let tlsMediaHeartbeatInterval: TimeInterval = 15

func tlsMediaSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    // A PTT channel is normally silent. Keep the request timeout comfortably beyond
    // the heartbeat cadence so an idle channel is not mistaken for a dead connection.
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    configuration.waitsForConnectivity = true
    return configuration
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
        URLSession(configuration: tlsMediaSessionConfiguration(), delegate: self, delegateQueue: nil)
    }()
    private var socket: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingSend: Task<Void, Never>?
    private var sendFailure: Error?
    private var opened = false
    private var closed = false
    private var failed = false

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

    public func flush() async throws {
        let pending = try lock.withLock { () -> Task<Void, Never>? in
            if let sendFailure { throw sendFailure }
            guard !closed, opened else { throw TlsMediaRelayError.closed }
            return pendingSend
        }
        await pending?.value
        try lock.withLock {
            if let sendFailure { throw sendFailure }
            guard !closed, opened else { throw TlsMediaRelayError.closed }
        }
    }

    public func close() {
        let state = lock.withLock { () -> (URLSessionWebSocketTask?, CheckedContinuation<Void, Error>?) in
            guard !closed else { return (nil, nil) }
            closed = true
            opened = false
            receiveTask?.cancel()
            heartbeatTask?.cancel()
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
        startHeartbeat(webSocketTask)
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

    private func startHeartbeat(_ task: URLSessionWebSocketTask) {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(tlsMediaHeartbeatInterval))
                    guard !Task.isCancelled else { return }
                    try await Self.sendPing(task)
                } catch is CancellationError {
                    return
                } catch {
                    self?.fail(error)
                    return
                }
            }
        }
    }

    private static func sendPing(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func fail(_ error: Error) {
        let state = lock.withLock { () -> (CheckedContinuation<Void, Error>?, URLSessionWebSocketTask?) in
            guard !closed, !failed else { return (nil, nil) }
            failed = true
            opened = false
            sendFailure = error
            receiveTask?.cancel()
            heartbeatTask?.cancel()
            pendingSend?.cancel()
            let continuation = opening
            opening = nil
            let task = socket
            socket = nil
            return (continuation, task)
        }
        guard state.0 != nil || state.1 != nil else { return }
        state.0?.resume(throwing: error)
        state.1?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        if state.0 == nil { onError(error) }
    }

    deinit { close() }
}

public final class AdaptiveMediaRelay: MediaRelay, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MediaRelay?
    private let serverUrl: String
    private let accessToken: String
    private let channelId: UUID
    private let onMedia: @Sendable (Data) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onConnectionStateChanged: @Sendable (MediaRelayConnectionState) -> Void
    private var closed = false
    private var recovering = false
    private var pendingFailure: Error?

    private init(
        serverUrl: String,
        accessToken: String,
        channelId: UUID,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onConnectionStateChanged: @escaping @Sendable (MediaRelayConnectionState) -> Void
    ) {
        self.serverUrl = serverUrl
        self.accessToken = accessToken
        self.channelId = channelId
        self.onMedia = onMedia
        self.onError = onError
        self.onConnectionStateChanged = onConnectionStateChanged
    }

    public var transportName: String {
        lock.withLock { current is AuthenticatedUdpRelay ? "UDP" : "TLS" }
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
        onConnectionStateChanged: @escaping @Sendable (MediaRelayConnectionState) -> Void = { _ in }
    ) async throws -> AdaptiveMediaRelay {
        let result = AdaptiveMediaRelay(
            serverUrl: serverUrl,
            accessToken: accessToken,
            channelId: channelId,
            onMedia: onMedia,
            onError: onError,
            onConnectionStateChanged: onConnectionStateChanged
        )
        do {
            let udp = try AuthenticatedUdpRelay.connect(
                publicAddress: publicAddress,
                ticket: ticket,
                expectedSenderDemux: expectedSenderDemux,
                onMedia: onMedia,
                onError: { [weak result] error in result?.recover(after: error) }
            )
            result.install(udp)
            return result
        } catch {
            let fallback = try await TlsMediaRelay.connect(
                serverUrl: serverUrl,
                accessToken: accessToken,
                channelId: channelId,
                onMedia: onMedia,
                onError: { [weak result] error in result?.recover(after: error) }
            )
            result.install(fallback)
            return result
        }
    }

    public func send(_ packet: Data) throws {
        do {
            try lock.withLock {
                guard !closed, let current else { throw TlsMediaRelayError.closed }
                try current.send(packet)
            }
        } catch {
            recover(after: error)
            throw error
        }
    }

    public func flush() async throws {
        let relay = try lock.withLock { () -> MediaRelay in
            guard !closed, let current else { throw TlsMediaRelayError.closed }
            return current
        }
        try await relay.flush()
    }

    public func close() {
        let relay = lock.withLock { () -> MediaRelay? in
            guard !closed else { return nil }
            closed = true
            let value = current
            current = nil
            return value
        }
        relay?.close()
    }

    private func install(_ relay: MediaRelay) {
        let failure = lock.withLock { () -> Error? in
            current = relay
            let value = pendingFailure
            pendingFailure = nil
            return value
        }
        if let failure { recover(after: failure) }
    }

    private func recover(after initialError: Error) {
        let failedRelay = lock.withLock { () -> MediaRelay? in
            guard !closed, !recovering else { return nil }
            guard current != nil else {
                pendingFailure = initialError
                return nil
            }
            recovering = true
            let value = current
            current = nil
            return value
        }
        guard let failedRelay else { return }
        failedRelay.close()
        Task { [weak self] in await self?.reconnectTls(after: initialError) }
    }

    private func reconnectTls(after initialError: Error) async {
        var lastError = initialError
        for attempt in 1...5 {
            guard !lock.withLock({ closed }) else { return }
            onConnectionStateChanged(.reconnecting(attempt: attempt))
            if attempt > 1 {
                try? await Task.sleep(for: .seconds(min(8, 1 << (attempt - 2))))
            }
            guard !lock.withLock({ closed }) else { return }
            do {
                let relay = try await TlsMediaRelay.connect(
                    serverUrl: serverUrl,
                    accessToken: accessToken,
                    channelId: channelId,
                    onMedia: onMedia,
                    onError: { [weak self] error in self?.recover(after: error) }
                )
                let installed = lock.withLock { () -> Bool in
                    guard !closed else { return false }
                    current = relay
                    recovering = false
                    return true
                }
                guard installed else { relay.close(); return }
                onConnectionStateChanged(.connected(transport: "TLS"))
                return
            } catch {
                lastError = error
            }
        }
        let shouldReport = lock.withLock { () -> Bool in
            guard !closed else { return false }
            recovering = false
            return true
        }
        if shouldReport {
            onConnectionStateChanged(.unavailable)
            onError(TlsMediaRelayError.fallbackFailed(udp: initialError, tls: lastError))
        }
    }

    deinit { close() }
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
