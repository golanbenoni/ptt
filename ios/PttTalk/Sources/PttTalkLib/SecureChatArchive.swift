import CryptoKit
import Foundation

private struct StoredChatRecord: Codable {
    let message: ChatMessage
    let expiresAt: Date
}

/// Chat metadata (including attachment keys) is encrypted with a device-only
/// Keychain key. Cached attachment bytes remain end-to-end ciphertext.
final class SecureChatArchive: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let key: SymmetricKey
    private let keyVault: KeychainVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumBytes: Int64

    init(
        namespace: String,
        directory: URL? = nil,
        testKey: Data? = nil,
        maximumBytes: Int64 = 1_000_000_000
    ) throws {
        guard maximumBytes > 0 else { throw EncryptedChatError.invalidMessage }
        self.maximumBytes = maximumBytes
        let vault = KeychainVault(service: "\(namespace).key")
        keyVault = vault
        let keyData: Data
        if let testKey {
            guard testKey.count == 32 else { throw EncryptedChatError.invalidMessage }
            keyData = testKey
        } else if let existing = try vault.get("archive-key") {
            guard existing.count == 32 else { throw EncryptedChatError.invalidMessage }
            keyData = existing
        } else {
            keyData = .random(count: 32)
            try vault.put("archive-key", keyData)
        }
        key = SymmetricKey(data: keyData)
        if let directory {
            root = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            root = base.appendingPathComponent(namespace, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func put(_ message: ChatMessage, expiresAt: Date, attachmentCiphertext: Data? = nil) throws {
        try lock.withLock {
            let url = metadataUrl(message.messageId)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try loadLocked(message.messageId)?.message == message else {
                    throw EncryptedChatError.invalidMessage
                }
                return
            }
            let clear = try encoder.encode(StoredChatRecord(message: message, expiresAt: expiresAt))
            let box = try AES.GCM.seal(clear, using: key, authenticating: aad(message.messageId))
            guard let combined = box.combined else { throw EncryptedChatError.invalidMessage }
            try protectedWrite(combined, to: url)
            if let attachmentCiphertext { try protectedWrite(attachmentCiphertext, to: objectUrl(message.messageId)) }
            try pruneLocked(now: Date())
        }
    }

    func messages(channelId: UUID) throws -> [ChatMessage] {
        try lock.withLock {
            try metadataUrls().compactMap { try loadLocked(id(from: $0)) }
                .filter { $0.message.channelId == channelId && $0.expiresAt > Date() }
                .map(\.message)
                .sorted { $0.sentAt < $1.sentAt }
        }
    }

    func attachmentCiphertext(messageId: UUID) throws -> Data? {
        try lock.withLock {
            let url = objectUrl(messageId)
            return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url, options: [.mappedIfSafe]) : nil
        }
    }

    func cacheAttachment(_ ciphertext: Data, messageId: UUID) throws {
        try lock.withLock {
            try protectedWrite(ciphertext, to: objectUrl(messageId))
            try pruneLocked(now: Date())
        }
    }

    func erase() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try keyVault.deleteAll()
        }
    }

    private func loadLocked(_ id: UUID) throws -> StoredChatRecord? {
        let url = metadataUrl(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let clear = try AES.GCM.open(box, using: key, authenticating: aad(id))
        let record = try decoder.decode(StoredChatRecord.self, from: clear)
        guard record.message.messageId == id else { throw EncryptedChatError.invalidMessage }
        return record
    }

    private func pruneLocked(now: Date) throws {
        var records = try metadataUrls().compactMap { url -> StoredChatRecord? in
            let record = try loadLocked(id(from: url))
            if let record, record.expiresAt <= now { try removeLocked(record.message.messageId); return nil }
            return record
        }
        var total = records.reduce(Int64(0)) { partial, record in
            partial + storedBytesLocked(record.message.messageId)
        }
        for record in records.sorted(by: { $0.message.sentAt < $1.message.sentAt }) where total > maximumBytes {
            let size = storedBytesLocked(record.message.messageId)
            try removeLocked(record.message.messageId)
            total -= size
        }
        records.removeAll()
    }

    private func storedBytesLocked(_ id: UUID) -> Int64 {
        [metadataUrl(id), objectUrl(id)].reduce(Int64(0)) { partial, url in
            partial + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func removeLocked(_ id: UUID) throws {
        for url in [metadataUrl(id), objectUrl(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
        #endif
    }

    private func metadataUrls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("message-") && $0.pathExtension == "bin" }
    }
    private func id(from url: URL) throws -> UUID {
        guard let value = UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(8))) else {
            throw EncryptedChatError.invalidMessage
        }
        return value
    }
    private func metadataUrl(_ id: UUID) -> URL { root.appendingPathComponent("message-\(id.uuidString.lowercased()).bin") }
    private func objectUrl(_ id: UUID) -> URL { root.appendingPathComponent("object-\(id.uuidString.lowercased()).bin") }
    private func aad(_ id: UUID) -> Data { Data("PTT-CHAT-LOCAL-V1/\(id.uuidString.lowercased())".utf8) }
}
