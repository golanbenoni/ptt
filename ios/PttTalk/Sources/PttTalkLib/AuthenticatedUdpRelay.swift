import Darwin
import Foundation
import PttWire

/// One authenticated UDP tuple bound to a relay lease for a single channel.
public final class AuthenticatedUdpRelay: MediaRelay, @unchecked Sendable {
    private let fd: Int32
    private let receiveThread: Thread
    private let stateLock = NSLock()
    private var closed = false

    private init(fd: Int32, receiveThread: Thread) {
        self.fd = fd
        self.receiveThread = receiveThread
    }

    public static func connect(
        publicAddress: String,
        ticket: String,
        expectedSenderDemux: UInt32,
        onMedia: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void = { _ in },
        heartbeatInterval: TimeInterval = 5,
        heartbeatTimeout: TimeInterval = 3
    ) throws -> AuthenticatedUdpRelay {
        guard !ticket.isEmpty, ticket.utf8.count <= 4_096 else {
            throw AuthenticatedRelayError.invalidTicket
        }
        guard expectedSenderDemux != 0 else { throw AuthenticatedRelayError.invalidDemux }
        guard heartbeatInterval > 0, heartbeatTimeout > 0 else {
            throw AuthenticatedRelayError.invalidHeartbeatTiming
        }
        let endpoint = try parseRelayEndpoint(publicAddress)
        let fd = try connectedDatagramSocket(host: endpoint.host, port: endpoint.port)
        let binding: Data = {
            var value = Data("PTTB".utf8)
            value.append(Data(ticket.utf8))
            return value
        }()
        do {
            try setReceiveTimeout(fd: fd, milliseconds: 3_000)
            try sendAllDatagram(fd: fd, binding)

            var ack = [UInt8](repeating: 0, count: 9)
            let ackLength = Darwin.recv(fd, &ack, ack.count, 0)
            guard ackLength == 8, Data(ack.prefix(4)) == Data("PTTA".utf8) else {
                throw AuthenticatedRelayError.invalidAcknowledgement
            }
            let acknowledged = ack[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard acknowledged == expectedSenderDemux else {
                throw AuthenticatedRelayError.wrongAcknowledgedDemux
            }
            try setReceiveTimeout(
                fd: fd,
                milliseconds: max(10, min(1_000, Int(heartbeatInterval * 1_000)))
            )
        } catch {
            Darwin.close(fd)
            throw error
        }

        let expectedAck: Data = {
            var value = Data("PTTA".utf8)
            var acknowledgedDemux = expectedSenderDemux.bigEndian
            withUnsafeBytes(of: &acknowledgedDemux) { value.append(contentsOf: $0) }
            return value
        }()
        let receiveThread = Thread {
            var buffer = [UInt8](repeating: 0, count: productionMediaDatagramBytes + 1)
            var nextProbeAt = Date().addingTimeInterval(heartbeatInterval)
            var probeDeadline: Date?
            while !Thread.current.isCancelled {
                let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                if count == productionMediaDatagramBytes {
                    onMedia(Data(buffer.prefix(count)))
                } else if count == expectedAck.count, Data(buffer.prefix(count)) == expectedAck {
                    probeDeadline = nil
                    nextProbeAt = Date().addingTimeInterval(heartbeatInterval)
                } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR, errno != EBADF {
                    onError(AuthenticatedRelayError.receiveFailed(errno))
                    return
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    let now = Date()
                    if let deadline = probeDeadline, now >= deadline {
                        onError(AuthenticatedRelayError.heartbeatTimedOut)
                        return
                    }
                    if probeDeadline == nil, now >= nextProbeAt {
                        do {
                            try sendAllDatagram(fd: fd, binding)
                            probeDeadline = now.addingTimeInterval(heartbeatTimeout)
                        } catch {
                            onError(error)
                            return
                        }
                    }
                }
            }
        }
        receiveThread.name = "ptt-udp-relay-receive"
        receiveThread.qualityOfService = .userInitiated
        let relay = AuthenticatedUdpRelay(fd: fd, receiveThread: receiveThread)
        receiveThread.start()
        return relay
    }

    public func send(_ packet: Data) throws {
        guard packet.count == productionMediaDatagramBytes else {
            throw AuthenticatedRelayError.invalidMediaLength
        }
        try stateLock.withLock {
            guard !closed else { throw AuthenticatedRelayError.closed }
            try sendAllDatagram(fd: fd, packet)
        }
    }

    public func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        receiveThread.cancel()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        if Thread.current !== receiveThread {
            let deadline = Date().addingTimeInterval(1)
            while !receiveThread.isFinished, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    deinit { close() }
}

public struct RelayEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
}

public func parseRelayEndpoint(_ value: String) throws -> RelayEndpoint {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AuthenticatedRelayError.invalidAddress }
    let normalized = trimmed.contains("://") ? trimmed : "udp://\(trimmed)"
    guard let components = URLComponents(string: normalized),
          components.scheme?.lowercased() == "udp",
          let host = components.host,
          !host.isEmpty,
          let integerPort = components.port,
          (1...65_535).contains(integerPort)
    else { throw AuthenticatedRelayError.invalidAddress }
    let normalizedHost = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host
    return RelayEndpoint(host: normalizedHost, port: UInt16(integerPort))
}

public enum AuthenticatedRelayError: Error, Equatable {
    case invalidAddress
    case invalidTicket
    case invalidDemux
    case invalidHeartbeatTiming
    case connectionFailed(Int32)
    case timeoutConfigurationFailed(Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case invalidAcknowledgement
    case wrongAcknowledgedDemux
    case heartbeatTimedOut
    case invalidMediaLength
    case closed
}

private func connectedDatagramSocket(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_DGRAM,
        ai_protocol: IPPROTO_UDP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else { throw AuthenticatedRelayError.invalidAddress }
    defer { freeaddrinfo(first) }

    var current: UnsafeMutablePointer<addrinfo>? = first
    var lastError: Int32 = ECONNREFUSED
    while let info = current?.pointee {
        let candidate = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        if candidate >= 0 {
            if Darwin.connect(candidate, info.ai_addr, info.ai_addrlen) == 0 { return candidate }
            lastError = errno
            Darwin.close(candidate)
        } else {
            lastError = errno
        }
        current = info.ai_next
    }
    throw AuthenticatedRelayError.connectionFailed(lastError)
}

private func setReceiveTimeout(fd: Int32, milliseconds: Int) throws {
    var timeout = timeval(
        tv_sec: milliseconds / 1_000,
        tv_usec: __darwin_suseconds_t((milliseconds % 1_000) * 1_000)
    )
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else { throw AuthenticatedRelayError.timeoutConfigurationFailed(errno) }
}

private func sendAllDatagram(fd: Int32, _ data: Data) throws {
    let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
    guard count == data.count else { throw AuthenticatedRelayError.sendFailed(errno) }
}
