import CryptoKit
import Foundation

public let sframeAes128GcmSha256128: UInt16 = 0x0004

public protocol SFrameCounterStore: AnyObject {
    /// Persists and returns an unused counter before any ciphertext is emitted.
    func takeNext(kid: UInt64) throws -> UInt64
}

public final class MemorySFrameCounterStore: SFrameCounterStore {
    private var next: [UInt64: UInt64] = [:]
    private let lock = NSLock()

    public init() {}

    public func takeNext(kid: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = next[kid, default: 0]
        guard value != UInt64.max else { throw SFrameError.counterExhausted }
        next[kid] = value + 1
        return value
    }
}

public final class SFrameEncryptor {
    private let kid: UInt64
    private let key: SymmetricKey
    private let salt: Data
    private let counters: SFrameCounterStore

    public init(kid: UInt64, baseKey: Data, counters: SFrameCounterStore) throws {
        guard !baseKey.isEmpty else { throw SFrameError.invalidKey }
        self.kid = kid
        self.key = SymmetricKey(data: derive(baseKey, info: label("SFrame 1.0 Secret key ", kid), count: 16))
        self.salt = derive(baseKey, info: label("SFrame 1.0 Secret salt ", kid), count: 12)
        self.counters = counters
    }

    public func encrypt(metadata: Data, plaintext: Data) throws -> Data {
        try encrypt(counter: counters.takeNext(kid: kid), metadata: metadata, plaintext: plaintext)
    }

    func encrypt(counter: UInt64, metadata: Data, plaintext: Data) throws -> Data {
        let header = SFrameHeader.encode(kid: kid, counter: counter)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: nonce(salt: salt, counter: counter)),
            authenticating: header + metadata
        )
        return header + sealed.ciphertext + sealed.tag
    }
}

public final class SFrameDecryptor {
    private struct Material {
        let key: SymmetricKey
        let salt: Data
    }

    private var keys: [UInt64: Material] = [:]
    private var replay: [UInt64: ReplayWindow] = [:]
    private let lock = NSLock()

    public init() {}

    public func addKey(kid: UInt64, baseKey: Data) throws {
        guard !baseKey.isEmpty else { throw SFrameError.invalidKey }
        lock.lock()
        defer { lock.unlock() }
        keys[kid] = Material(
            key: SymmetricKey(data: derive(baseKey, info: label("SFrame 1.0 Secret key ", kid), count: 16)),
            salt: derive(baseKey, info: label("SFrame 1.0 Secret salt ", kid), count: 12)
        )
        replay.removeValue(forKey: kid)
    }

    public func removeKey(kid: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: kid)
        replay.removeValue(forKey: kid)
    }

    public func decrypt(metadata: Data, frame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let parsed = try SFrameHeader.parse(frame)
        guard let material = keys[parsed.kid] else { throw SFrameError.unknownKey }
        var window = replay[parsed.kid, default: ReplayWindow()]
        guard window.acceptable(parsed.counter) else { throw SFrameError.replay }
        guard frame.count >= parsed.length + 16 else { throw SFrameError.malformedHeader }
        let ciphertext = frame[parsed.length..<(frame.count - 16)]
        let tag = frame.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce(salt: material.salt, counter: parsed.counter)),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: material.key,
                authenticating: frame.prefix(parsed.length) + metadata
            )
            window.mark(parsed.counter)
            replay[parsed.kid] = window
            return plaintext
        } catch {
            throw SFrameError.authenticationFailed
        }
    }
}

public enum SFrameError: Error, Equatable {
    case invalidKey
    case counterExhausted
    case malformedHeader
    case unknownKey
    case authenticationFailed
    case replay
}

private struct ParsedSFrameHeader {
    let kid: UInt64
    let counter: UInt64
    let length: Int
}

private enum SFrameHeader {
    static func encode(kid: UInt64, counter: UInt64) -> Data {
        let kidBytes = compact(kid)
        let counterBytes = compact(counter)
        let kidExtended = kid >= 8
        let counterExtended = counter >= 8
        var config: UInt8 = 0
        if kidExtended {
            config |= 0x80 | UInt8((kidBytes.count - 1) << 4)
        } else {
            config |= UInt8(kid << 4)
        }
        if counterExtended {
            config |= 0x08 | UInt8(counterBytes.count - 1)
        } else {
            config |= UInt8(counter)
        }
        var output = Data([config])
        if kidExtended { output.append(contentsOf: kidBytes) }
        if counterExtended { output.append(contentsOf: counterBytes) }
        return output
    }

    static func parse(_ frame: Data) throws -> ParsedSFrameHeader {
        guard let config = frame.first else { throw SFrameError.malformedHeader }
        let kidExtended = config & 0x80 != 0
        let counterExtended = config & 0x08 != 0
        let kidLength = kidExtended ? Int((config >> 4) & 0x07) + 1 : 0
        let counterLength = counterExtended ? Int(config & 0x07) + 1 : 0
        let length = 1 + kidLength + counterLength
        guard frame.count >= length else { throw SFrameError.malformedHeader }
        var offset = 1
        let kid: UInt64
        if kidExtended {
            kid = try decode(frame, offset: offset, length: kidLength)
            offset += kidLength
        } else {
            kid = UInt64((config >> 4) & 0x07)
        }
        let counter = counterExtended
            ? try decode(frame, offset: offset, length: counterLength)
            : UInt64(config & 0x07)
        guard (!kidExtended || kid >= 8), (!counterExtended || counter >= 8) else {
            throw SFrameError.malformedHeader
        }
        return ParsedSFrameHeader(kid: kid, counter: counter, length: length)
    }

    private static func compact(_ value: UInt64) -> [UInt8] {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        let first = bytes.firstIndex(where: { $0 != 0 }) ?? 7
        return Array(bytes[first...])
    }

    private static func decode(_ data: Data, offset: Int, length: Int) throws -> UInt64 {
        guard (1...8).contains(length), !(length > 1 && data[offset] == 0) else {
            throw SFrameError.malformedHeader
        }
        return data[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private struct ReplayWindow {
    private var initialized = false
    private var highest: UInt64 = 0
    private var low: UInt64 = 0
    private var high: UInt64 = 0

    func acceptable(_ counter: UInt64) -> Bool {
        guard initialized, counter <= highest else { return true }
        let distance = highest - counter
        guard distance < 128 else { return false }
        if distance < 64 { return low & (1 << distance) == 0 }
        return high & (1 << (distance - 64)) == 0
    }

    mutating func mark(_ counter: UInt64) {
        guard initialized else {
            initialized = true
            highest = counter
            low = 1
            return
        }
        if counter > highest {
            let distance = counter - highest
            if distance >= 128 {
                low = 1
                high = 0
            } else if distance >= 64 {
                high = low << (distance - 64)
                low = 1
            } else {
                high = (high << distance) | (low >> (64 - distance))
                low = (low << distance) | 1
            }
            highest = counter
        } else {
            let distance = highest - counter
            if distance < 64 { low |= 1 << distance }
            else { high |= 1 << (distance - 64) }
        }
    }
}

private func label(_ prefix: String, _ kid: UInt64) -> Data {
    var output = Data(prefix.utf8)
    var bigEndianKid = kid.bigEndian
    output.append(Data(bytes: &bigEndianKid, count: 8))
    var suite = sframeAes128GcmSha256128.bigEndian
    output.append(Data(bytes: &suite, count: 2))
    return output
}

private func derive(_ baseKey: Data, info: Data, count: Int) -> Data {
    let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: baseKey),
        salt: Data(),
        info: info,
        outputByteCount: count
    )
    return key.withUnsafeBytes { Data($0) }
}

private func nonce(salt: Data, counter: UInt64) -> Data {
    var output = Array(salt)
    let counterBytes = withUnsafeBytes(of: counter.bigEndian) { Array($0) }
    for index in counterBytes.indices { output[output.count - 8 + index] ^= counterBytes[index] }
    return Data(output)
}
