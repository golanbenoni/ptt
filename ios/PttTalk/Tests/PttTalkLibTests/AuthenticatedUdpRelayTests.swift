import Darwin
import Foundation
import Testing
@testable import PttTalkLib

@Test func tlsMediaEndpointUsesWebSocketTlsAndCanonicalChannelQuery() throws {
    let channel = UUID(uuidString: "54b86f25-447f-4abc-a885-7c2e6b2c109c")!
    #expect(
        try tlsMediaWebSocketUrl(
            serverUrl: "https://ptt.example.test/ignored?secret=no",
            channelId: channel
        ).absoluteString
            == "wss://ptt.example.test/v1/media/tunnel?channelId=54b86f25-447f-4abc-a885-7c2e6b2c109c"
    )
    #expect(
        try tlsMediaWebSocketUrl(serverUrl: "http://127.0.0.1:8080", channelId: channel).scheme == "ws"
    )
}

@Test func relayEndpointAcceptsHostnamesIpv4AndIpv6() throws {
    #expect(try parseRelayEndpoint("relay.example:47000") == RelayEndpoint(host: "relay.example", port: 47_000))
    #expect(try parseRelayEndpoint("udp://127.0.0.1:9") == RelayEndpoint(host: "127.0.0.1", port: 9))
    #expect(try parseRelayEndpoint("udp://[::1]:65535") == RelayEndpoint(host: "::1", port: 65_535))
}

@Test func relayEndpointRejectsAmbiguity() {
    for value in ["", "127.0.0.1", "tcp://127.0.0.1:9", "udp://:9", "udp://host:0"] {
        #expect(throws: AuthenticatedRelayError.invalidAddress) {
            try parseRelayEndpoint(value)
        }
    }
}

@Test func missingAuthenticatedHeartbeatDetectsSilentUdpFailure() throws {
    let server = try UdpHeartbeatServer()
    let heartbeatSeen = DispatchSemaphore(value: 0)
    let failureSeen = DispatchSemaphore(value: 0)
    let worker = Thread {
        guard let first = server.receive(), first.data == Data("PTTBticket".utf8) else { return }
        var ack = Data("PTTA".utf8)
        var demux = UInt32(42).bigEndian
        withUnsafeBytes(of: &demux) { ack.append(contentsOf: $0) }
        guard server.send(ack, to: first.source, length: first.sourceLength) else { return }
        guard let heartbeat = server.receive(), heartbeat.data == Data("PTTBticket".utf8) else { return }
        heartbeatSeen.signal()
        // Deliberately omit the second acknowledgement to model a UDP black hole.
    }
    worker.start()
    let relay = try AuthenticatedUdpRelay.connect(
        publicAddress: "127.0.0.1:\(server.port)",
        ticket: "ticket",
        expectedSenderDemux: 42,
        onMedia: { _ in },
        onError: { _ in failureSeen.signal() },
        heartbeatInterval: 0.05,
        heartbeatTimeout: 0.1
    )
    defer {
        relay.close()
        server.close()
    }
    #expect(heartbeatSeen.wait(timeout: .now() + 2) == .success)
    #expect(failureSeen.wait(timeout: .now() + 2) == .success)
}

private final class UdpHeartbeatServer: @unchecked Sendable {
    struct Received {
        let data: Data
        let source: sockaddr_storage
        let sourceLength: socklen_t
    }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init() throws {
        let socketFd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFd >= 0 else { throw Self.posixError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFd)
            throw Self.posixError()
        }
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketFd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketFd)
            throw Self.posixError()
        }
        fd = socketFd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func receive() -> Received? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        var source = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &source) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &sourceLength)
            }
        }
        guard count > 0 else { return nil }
        return Received(data: Data(bytes.prefix(count)), source: source, sourceLength: sourceLength)
    }

    func send(_ data: Data, to source: sockaddr_storage, length: socklen_t) -> Bool {
        var source = source
        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, bytes.baseAddress, data.count, 0, $0, length) == data.count
                }
            }
        }
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose { Darwin.close(fd) }
    }

    deinit { close() }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
