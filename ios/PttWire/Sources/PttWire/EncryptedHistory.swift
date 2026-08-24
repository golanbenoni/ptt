import CryptoKit
import Foundation

/// End-to-end wrapper for persisted SFrame datagrams. The wrapper authenticates packet ordering
/// and routing headers while the object store sees only ciphertext.
public enum EncryptedHistory {
    private static let magic = Data("PTTH".utf8)
    private static let version: UInt8 = 1
    private static let nonceBytes = 12
    private static let maximumFrames = 1_501
    private static let info = Data("PTT Talk encrypted history v1".utf8)

    public static func seal(
        channelId: UUID,
        talkId: UUID,
        membershipEpoch: Int32,
        kid: UInt64,
        baseKey: Data,
        packets: [Data],
        nonce: Data? = nil
    ) throws -> Data {
        let actualNonce = nonce ?? randomNonce()
        try validate(epoch: membershipEpoch, key: baseKey, packets: packets, nonce: actualNonce)
        var plaintext = Data()
        appendBigEndian(UInt32(packets.count), to: &plaintext)
        packets.forEach { plaintext.append($0) }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: deriveKey(baseKey),
            nonce: AES.GCM.Nonce(data: actualNonce),
            authenticating: aad(channelId, talkId, membershipEpoch, kid)
        )
        var output = magic
        output.append(version)
        output.append(actualNonce)
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    public static func open(
        _ blob: Data,
        channelId: UUID,
        talkId: UUID,
        membershipEpoch: Int32,
        kid: UInt64,
        baseKey: Data
    ) throws -> [Data] {
        guard blob.count >= magic.count + 1 + nonceBytes + 4 + 16,
              blob.prefix(magic.count) == magic else { throw EncryptedHistoryError.invalidObject }
        guard blob[magic.count] == version else { throw EncryptedHistoryError.unsupportedVersion }
        guard membershipEpoch > 0, baseKey.count == 32 else { throw EncryptedHistoryError.invalidMetadata }
        let nonceStart = magic.count + 1
        let nonce = blob.subdata(in: nonceStart..<(nonceStart + nonceBytes))
        let sealed = blob.suffix(from: nonceStart + nonceBytes)
        guard sealed.count >= 16 else { throw EncryptedHistoryError.invalidObject }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: sealed.dropLast(16),
            tag: sealed.suffix(16)
        )
        let plaintext = try AES.GCM.open(
            box,
            using: deriveKey(baseKey),
            authenticating: aad(channelId, talkId, membershipEpoch, kid)
        )
        guard plaintext.count >= 4 else { throw EncryptedHistoryError.invalidObject }
        let count = Int(readUInt32(plaintext, at: 0))
        guard (1...maximumFrames).contains(count),
              plaintext.count == 4 + count * productionMediaDatagramBytes
        else { throw EncryptedHistoryError.invalidObject }
        return (0..<count).map { index in
            let start = 4 + index * productionMediaDatagramBytes
            return plaintext.subdata(in: start..<(start + productionMediaDatagramBytes))
        }
    }

    private static func validate(epoch: Int32, key: Data, packets: [Data], nonce: Data) throws {
        guard epoch > 0, key.count == 32 else { throw EncryptedHistoryError.invalidMetadata }
        guard nonce.count == nonceBytes else { throw EncryptedHistoryError.invalidNonce }
        guard (1...maximumFrames).contains(packets.count),
              packets.allSatisfy({ $0.count == productionMediaDatagramBytes })
        else { throw EncryptedHistoryError.invalidObject }
    }

    private static func aad(_ channelId: UUID, _ talkId: UUID, _ epoch: Int32, _ kid: UInt64) -> Data {
        var output = magic
        output.append(version)
        output.append(contentsOf: PttWire.uuidBytes(channelId))
        output.append(contentsOf: PttWire.uuidBytes(talkId))
        appendBigEndian(UInt32(bitPattern: epoch), to: &output)
        appendBigEndian(kid, to: &output)
        return output
    }

    private static func deriveKey(_ input: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: Data(repeating: 0, count: 32),
            info: info,
            outputByteCount: 32
        )
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, nonceBytes, &bytes) == errSecSuccess)
        return Data(bytes)
    }
}

public enum EncryptedHistoryError: Error, Equatable {
    case invalidObject
    case unsupportedVersion
    case invalidMetadata
    case invalidNonce
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.bigEndian
    data.append(Data(bytes: &encoded, count: MemoryLayout<T>.size))
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
}
