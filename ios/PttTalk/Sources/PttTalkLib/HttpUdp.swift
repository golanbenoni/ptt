import Darwin
import Foundation

enum PttHttp {
    static func request(method: String, url: URL, body: Data? = nil) throws -> (status: Int, body: Data) {
        guard let host = url.host else { throw TalkError("bad url \(url)") }
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?\(q)" }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw TalkError("http socket errno=\(errno)") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let parsed = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parsed == 1 else { throw TalkError("inet_pton \(host)") }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw TalkError("connect \(host):\(port) errno=\(errno)") }

        var header =
            "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n"
        if let body {
            header += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        if let body { payload.append(body) }

        try writeAll(fd: fd, payload)

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n == 0 { break }
            if n < 0 { throw TalkError("http recv errno=\(errno)") }
            resp.append(contentsOf: buf.prefix(n))
        }
        guard let split = resp.range(of: Data("\r\n\r\n".utf8)) else {
            throw TalkError("truncated http response")
        }
        let head = String(decoding: resp[..<split.lowerBound], as: UTF8.self)
        let status = Int(head.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? 0
        return (status, Data(resp[split.upperBound...]))
    }

    private static func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            let total = data.count
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw TalkError("http send empty")
            }
            while sent < total {
                let n = Darwin.send(fd, base + sent, total - sent, 0)
                if n <= 0 { throw TalkError("http send errno=\(errno)") }
                sent += n
            }
        }
    }
}

final class UdpSocket {
    private let fd: Int32

    init() throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw TalkError("udp socket errno=\(errno)") }
        fd = s
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    /// Pin the 5-tuple so iOS Simulator delivers inbound UDP from the relay.
    func connect(host: String, port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let parsed = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parsed == 1 else { throw TalkError("udp inet_pton \(host)") }
        let n = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard n == 0 else { throw TalkError("udp connect errno=\(errno)") }
    }

    func send(_ data: Data, host _: String, port _: UInt16) throws {
        // Socket is connected; sendto() on iOS returns ENOTCONN (56).
        let n = data.withUnsafeBytes { raw -> Int in
            Darwin.send(fd, raw.baseAddress, data.count, 0)
        }
        guard n == data.count else { throw TalkError("udp send errno=\(errno) n=\(n)") }
    }

    func receive(timeoutMs: Int) throws -> Data? {
        var tv = timeval(
            tv_sec: timeoutMs / 1000,
            tv_usec: suseconds_t((timeoutMs % 1000) * 1000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw TalkError("udp recv errno=\(errno)")
        }
        return Data(buf.prefix(n))
    }
}
