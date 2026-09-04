import CryptoKit
import Foundation
import PttWire

struct StoredVoiceHistory: Codable, Equatable, Sendable {
    let talkId: UUID
    let channelId: UUID
    let membershipEpoch: Int32
    let mediaKid: String
    let baseKey: Data
    let senderDemux: UInt32
    let senderAci: String
    let senderDeviceId: Int
    let announcedAt: Date
    var objectId: UUID?
    var startedAt: Date?
    var durationMs: Int?
    var expiresAt: Date?
    var ciphertextBytes: Int?
    var isSos: Bool?
}

/// Metadata and media keys are encrypted with a device-only key kept in Keychain. Media blobs are
/// already end-to-end encrypted and receive iOS file protection as a second at-rest layer.
final class SecureVoiceHistoryArchive: @unchecked Sendable {
    private let lock = NSLock()
    private let vault: KeychainVault
    private let root: URL
    private let key: SymmetricKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maximumBytes: Int64 = 1_000_000_000

    init(namespace: String, directory: URL? = nil, testKey: Data? = nil) throws {
        vault = KeychainVault(service: "\(namespace).key")
        let keyData: Data
        if let testKey {
            guard testKey.count == 32 else { throw KeychainStoreError.corruptRecord }
            keyData = testKey
        } else if let existing = try vault.get("archive-key") {
            guard existing.count == 32 else { throw KeychainStoreError.corruptRecord }
            keyData = existing
        } else {
            keyData = Data.random(count: 32)
            try vault.put("archive-key", keyData)
        }
        key = SymmetricKey(data: keyData)
        if let directory {
            root = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            root = base.appendingPathComponent(namespace, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func putEpoch(
        _ announcement: MediaEpochAnnouncement,
        senderAci: String,
        senderDeviceId: Int,
        announcedAt: Date = Date()
    ) throws {
        try lock.withLock {
            if let existing = try loadLocked(announcement.talkId) {
                guard existing.channelId == announcement.channelId,
                      existing.membershipEpoch == announcement.membershipEpoch,
                      existing.mediaKid == String(announcement.kid),
                      existing.baseKey == announcement.baseKey,
                      existing.senderDemux == announcement.senderDemux,
                      existing.senderAci == senderAci,
                      existing.senderDeviceId == senderDeviceId,
                      (existing.isSos ?? false) == announcement.isSos
                else { throw SecureVoiceHistoryError.talkIdReused }
                return
            }
            try writeLocked(StoredVoiceHistory(
                talkId: announcement.talkId,
                channelId: announcement.channelId,
                membershipEpoch: announcement.membershipEpoch,
                mediaKid: String(announcement.kid),
                baseKey: announcement.baseKey,
                senderDemux: announcement.senderDemux,
                senderAci: senderAci,
                senderDeviceId: senderDeviceId,
                announcedAt: announcedAt,
                objectId: nil,
                startedAt: nil,
                durationMs: nil,
                expiresAt: nil,
                ciphertextBytes: nil,
                isSos: announcement.isSos
            ))
        }
    }

    func record(_ talkId: UUID) throws -> StoredVoiceHistory? {
        try lock.withLock { try loadLocked(talkId) }
    }

    func records(channelId: UUID, includePending: Bool = false) throws -> [StoredVoiceHistory] {
        try lock.withLock {
            try metadataUrls().compactMap { try loadLocked(talkId(from: $0)) }
                .filter { $0.channelId == channelId && (includePending || $0.objectId != nil) }
                .sorted { ($0.startedAt ?? $0.announcedAt) > ($1.startedAt ?? $1.announcedAt) }
        }
    }

    func stageUpload(
        talkId: UUID,
        startedAt: Date,
        durationMs: Int,
        ciphertext: Data
    ) throws {
        try lock.withLock {
            guard var record = try loadLocked(talkId), record.objectId == nil,
                  (1...30_000).contains(durationMs), !ciphertext.isEmpty,
                  let kid = UInt64(record.mediaKid)
            else { throw SecureVoiceHistoryError.missingEpoch }
            _ = try EncryptedHistory.open(
                ciphertext,
                channelId: record.channelId,
                talkId: record.talkId,
                membershipEpoch: record.membershipEpoch,
                kid: kid,
                baseKey: record.baseKey
            )
            try protectedWrite(ciphertext, to: objectUrl(record.talkId))
            record.startedAt = startedAt
            record.durationMs = durationMs
            record.ciphertextBytes = ciphertext.count
            try writeLocked(record)
            try pruneLocked(now: Date())
        }
    }

    func pendingUploads(channelId: UUID? = nil) throws -> [StoredVoiceHistory] {
        try lock.withLock {
            try metadataUrls().compactMap { try loadLocked(talkId(from: $0)) }
                .filter {
                    (channelId == nil || $0.channelId == channelId) && $0.objectId == nil &&
                        $0.startedAt != nil && $0.durationMs != nil &&
                        FileManager.default.fileExists(atPath: objectUrl($0.talkId).path)
                }
                .sorted { ($0.startedAt ?? $0.announcedAt) < ($1.startedAt ?? $1.announcedAt) }
        }
    }

    func pendingCiphertext(_ talkId: UUID) throws -> Data {
        try lock.withLock {
            guard let record = try loadLocked(talkId), record.objectId == nil,
                  record.startedAt != nil, record.durationMs != nil,
                  FileManager.default.fileExists(atPath: objectUrl(talkId).path)
            else { throw SecureVoiceHistoryError.missingObject }
            return try Data(contentsOf: objectUrl(talkId), options: [.mappedIfSafe])
        }
    }

    func complete(metadata: HistoryMetadata, ciphertext: Data) throws {
        try lock.withLock {
            guard var record = try loadLocked(metadata.talkId), record.objectId == nil,
                  record.channelId == metadata.channelId,
                  Int(record.membershipEpoch) == metadata.membershipEpoch,
                  record.mediaKid == String(metadata.mediaKid)
            else { throw SecureVoiceHistoryError.missingEpoch }
            _ = try EncryptedHistory.open(
                ciphertext,
                channelId: record.channelId,
                talkId: record.talkId,
                membershipEpoch: record.membershipEpoch,
                kid: metadata.mediaKid,
                baseKey: record.baseKey
            )
            try protectedWrite(ciphertext, to: objectUrl(record.talkId))
            record.objectId = metadata.objectId
            record.startedAt = metadata.startedAt
            record.durationMs = metadata.durationMs
            record.expiresAt = metadata.expiresAt
            record.ciphertextBytes = ciphertext.count
            try writeLocked(record)
            try pruneLocked(now: Date())
        }
    }

    func packets(_ talkId: UUID) throws -> [Data] {
        try lock.withLock {
            guard let record = try loadLocked(talkId), record.objectId != nil,
                  let kid = UInt64(record.mediaKid)
            else { throw SecureVoiceHistoryError.missingObject }
            let ciphertext = try Data(contentsOf: objectUrl(talkId), options: [.mappedIfSafe])
            return try EncryptedHistory.open(
                ciphertext,
                channelId: record.channelId,
                talkId: record.talkId,
                membershipEpoch: record.membershipEpoch,
                kid: kid,
                baseKey: record.baseKey
            )
        }
    }

    private func pruneLocked(now: Date) throws {
        var complete = try metadataUrls().compactMap { try loadLocked(talkId(from: $0)) }
        for record in complete where record.expiresAt.map({ $0 <= now }) == true {
            try removeLocked(record.talkId)
        }
        complete = complete.filter { $0.expiresAt.map({ $0 > now }) ?? true }
        var total = complete.reduce(Int64(0)) { $0 + Int64($1.ciphertextBytes ?? 0) }
        for record in complete.sorted(by: { ($0.startedAt ?? $0.announcedAt) < ($1.startedAt ?? $1.announcedAt) })
            where total > maximumBytes {
            total -= Int64(record.ciphertextBytes ?? 0)
            try removeLocked(record.talkId)
        }
    }

    private func loadLocked(_ talkId: UUID) throws -> StoredVoiceHistory? {
        let url = metadataUrl(talkId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let combined = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(talkId.uuidString.lowercased().utf8))
        let value = try decoder.decode(StoredVoiceHistory.self, from: plaintext)
        guard value.talkId == talkId else { throw SecureVoiceHistoryError.corruptMetadata }
        return value
    }

    private func writeLocked(_ record: StoredVoiceHistory) throws {
        let plaintext = try encoder.encode(record)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(record.talkId.uuidString.lowercased().utf8)
        )
        guard let combined = box.combined else { throw SecureVoiceHistoryError.corruptMetadata }
        try protectedWrite(combined, to: metadataUrl(record.talkId))
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func removeLocked(_ talkId: UUID) throws {
        for url in [metadataUrl(talkId), objectUrl(talkId)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func metadataUrls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("meta-") && $0.pathExtension == "bin" }
    }

    private func talkId(from url: URL) throws -> UUID {
        let value = url.deletingPathExtension().lastPathComponent.dropFirst("meta-".count)
        guard let id = UUID(uuidString: String(value)) else { throw SecureVoiceHistoryError.corruptMetadata }
        return id
    }

    private func metadataUrl(_ talkId: UUID) -> URL {
        root.appendingPathComponent("meta-\(talkId.uuidString.lowercased()).bin")
    }

    private func objectUrl(_ talkId: UUID) -> URL {
        root.appendingPathComponent("object-\(talkId.uuidString.lowercased()).bin")
    }
}

enum SecureVoiceHistoryError: Error, Equatable {
    case talkIdReused
    case missingEpoch
    case missingObject
    case corruptMetadata
}
