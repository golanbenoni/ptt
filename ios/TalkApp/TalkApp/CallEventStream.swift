import Foundation
import PttTalkLib

struct CallCoordinationEvent: Decodable, Sendable {
    let protocolVersion: Int
    let callId: UUID
    let type: String
}

/// Foreground coordination stream. PushKit remains the authoritative wake path;
/// this stream removes polling latency while the app is active.
final class CallEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    func start(session: DeviceSession, handler: @escaping @MainActor (CallCoordinationEvent) async -> Void) {
        stop()
        task = Task {
            var retryNanoseconds: UInt64 = 500_000_000
            while !Task.isCancelled {
                do {
                    var components = URLComponents(string: session.serverUrl)
                    let sourceScheme = components?.scheme
                    let allowsPlaintext: Bool
#if DEBUG
                    allowsPlaintext = sourceScheme == "http"
#else
                    allowsPlaintext = false
#endif
                    guard sourceScheme == "https" || allowsPlaintext else { return }
                    components?.scheme = sourceScheme == "https" ? "wss" : "ws"
                    components?.path = "/v1/calls/events"
                    guard let url = components?.url else { return }
                    var request = URLRequest(url: url, timeoutInterval: 45)
                    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                    let socket = URLSession.shared.webSocketTask(with: request)
                    replaceSocket(with: socket)
                    socket.resume()
                    let keepalive = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(20))
                            try await Self.ping(socket)
                        }
                    }
                    defer {
                        keepalive.cancel()
                        socket.cancel(with: .goingAway, reason: nil)
                        clearSocket(ifMatching: socket)
                    }
                    retryNanoseconds = 500_000_000
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let value): data = Data(value.utf8)
                        case .data(let value): data = value
                        @unknown default: continue
                        }
                        let event = try JSONDecoder().decode(CallCoordinationEvent.self, from: data)
                        guard event.protocolVersion == 1,
                              ["ringing", "answered", "roster_changed", "ended"].contains(event.type) else { continue }
                        await handler(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: retryNanoseconds)
                    retryNanoseconds = min(retryNanoseconds * 2, 15_000_000_000)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lock.lock()
        let active = socket
        socket = nil
        lock.unlock()
        active?.cancel(with: .goingAway, reason: nil)
    }

    private func replaceSocket(with newSocket: URLSessionWebSocketTask) {
        lock.lock()
        let previous = socket
        socket = newSocket
        lock.unlock()
        previous?.cancel(with: .goingAway, reason: nil)
    }

    private func clearSocket(ifMatching expected: URLSessionWebSocketTask) {
        lock.lock()
        if socket === expected { socket = nil }
        lock.unlock()
    }

    private static func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    deinit {
        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }
}
