import CryptoKit
import Foundation

/// Legacy golden-vector fixture. Production media uses RFC 9605 SFrame.
/// Wire: 8-byte big-endian counter || ciphertext+tag (16-byte tag).
/// Nonce is 12 bytes: 4 zero || counter u64 BE. Matches `app.ptt.media.AesGcmFrames`.
public enum AesGcmFrames {
    public static func newKey() -> Data {
        let key = SymmetricKey(size: .bits128)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func nonce(counter: UInt64) -> Data {
        var n = Data(count: 12)
        var be = counter.bigEndian
        let counterBytes = Data(bytes: &be, count: 8)
        n.replaceSubrange(4..<12, with: counterBytes)
        return n
    }

    public static func encrypt(key: Data, counter: UInt64, aad: Data, plaintext: Data) throws -> Data {
        let sk = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: Self.nonce(counter: counter))
        let sealed = try AES.GCM.seal(plaintext, using: sk, nonce: nonce, authenticating: aad)
        var out = Data()
        var be = counter.bigEndian
        out.append(Data(bytes: &be, count: 8))
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public static func decrypt(key: Data, aad: Data, packet: Data) throws -> Data {
        guard packet.count > 8 + 16 else { throw AesGcmError.shortFrame }
        var counter: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &counter) { dest in
            packet.copyBytes(to: dest, from: 0..<8)
        }
        counter = UInt64(bigEndian: counter)
        let rest = packet.dropFirst(8)
        let ciphertext = rest.dropLast(16)
        let tag = rest.suffix(16)
        let sk = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: Self.nonce(counter: counter))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        return try AES.GCM.open(box, using: sk, authenticating: aad)
    }

    public enum AesGcmError: Error {
        case shortFrame
    }
}
