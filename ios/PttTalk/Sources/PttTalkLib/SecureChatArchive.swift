import CryptoKit
import Foundation

private struct StoredChatRecord: Codable {
    let message: ChatMessage
    let expiresAt: Date
}

private struct StoredChatEventRecord: Codable {
    let event: ChatEvent
    let expiresAt: Date
}

enum ChatOutboxState: String, Codable, Equatable, Sendable {
    case queued
    case sending
    case failed
}

private struct StoredChatRecipient: Codable, Equatable {
    let aci: String
    let deviceId: Int
    let envelope: Data
}

struct ChatOutboxItem: Equatable, Sendable {
    let event: ChatEvent
    let recipients: [ChatRecipient]
    let expiresAt: Date
    let state: ChatOutboxState
    let attemptCount: Int
    let lastErrorCode: String?
}

private struct StoredChatOutboxRecord: Codable {
    let event: ChatEvent
    let recipients: [StoredChatRecipient]
    let expiresAt: Date
    var state: ChatOutboxState
    var attemptCount: Int
    var lastErrorCode: String?
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

    func putEvent(_ event: ChatEvent, expiresAt: Date, attachmentCiphertext: Data? = nil) throws {
        if let message = event.message {
            try put(message, expiresAt: expiresAt, attachmentCiphertext: attachmentCiphertext)
        }
        try lock.withLock {
            let url = eventMetadataUrl(event.eventId)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try loadEventLocked(event.eventId)?.event == event else {
                    throw EncryptedChatError.invalidEvent
                }
                return
            }
            let clear = try encoder.encode(StoredChatEventRecord(event: event, expiresAt: expiresAt))
            let box = try AES.GCM.seal(clear, using: key, authenticating: eventAad(event.eventId))
            guard let combined = box.combined else { throw EncryptedChatError.invalidEvent }
            try protectedWrite(combined, to: url)
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

    func events(channelId: UUID) throws -> [ChatEvent] {
        try lock.withLock {
            let stored = try eventMetadataUrls().compactMap { try loadEventLocked(id(from: $0, prefixCount: 6)) }
                .filter { $0.event.channelId == channelId && $0.expiresAt > Date() }
                .map(\.event)
            let eventIds = Set(stored.map(\.eventId))
            let legacy = try metadataUrls().compactMap { try loadLocked(id(from: $0)) }
                .filter { $0.message.channelId == channelId && $0.expiresAt > Date() && !eventIds.contains($0.message.messageId) }
                .map { ChatEvent.message($0.message) }
            return (stored + legacy).sorted {
                if $0.sentAt != $1.sentAt { return $0.sentAt < $1.sentAt }
                return $0.eventId.uuidString < $1.eventId.uuidString
            }
        }
    }

    func conversation(channelId: UUID, localAci: String) throws -> [ChatConversationMessage] {
        try ChatEventReducer.reduce(events(channelId: channelId), channelId: channelId, localAci: localAci)
    }

    func unreadCount(channelId: UUID, localAci: String) throws -> Int {
        try conversation(channelId: channelId, localAci: localAci).filter(\.isUnread).count
    }

    func putOutbox(event: ChatEvent, recipients: [ChatRecipient], expiresAt: Date) throws {
        try lock.withLock {
            let url = outboxUrl(event.eventId)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let existing = try loadOutboxLocked(event.eventId), existing.event == event else {
                    throw EncryptedChatError.invalidEvent
                }
                return
            }
            let record = StoredChatOutboxRecord(
                event: event,
                recipients: recipients.map { StoredChatRecipient(aci: $0.aci, deviceId: $0.deviceId, envelope: $0.envelope) },
                expiresAt: expiresAt, state: .queued, attemptCount: 0, lastErrorCode: nil
            )
            try writeOutboxLocked(record)
        }
    }

    func outbox() throws -> [ChatOutboxItem] {
        try lock.withLock {
            var result: [ChatOutboxItem] = []
            for url in try outboxUrls() {
                let id = try id(from: url, prefixCount: 7)
                guard let record = try loadOutboxLocked(id) else { continue }
                if record.expiresAt <= Date() {
                    try removeOutboxLocked(id)
                    continue
                }
                result.append(ChatOutboxItem(
                    event: record.event,
                    recipients: record.recipients.map { ChatRecipient(aci: $0.aci, deviceId: $0.deviceId, envelope: $0.envelope) },
                    expiresAt: record.expiresAt, state: record.state,
                    attemptCount: record.attemptCount, lastErrorCode: record.lastErrorCode
                ))
            }
            return result.sorted {
                if $0.event.sentAt != $1.event.sentAt { return $0.event.sentAt < $1.event.sentAt }
                return $0.event.eventId.uuidString < $1.event.eventId.uuidString
            }
        }
    }

    func markOutbox(_ eventId: UUID, state: ChatOutboxState, errorCode: String? = nil) throws {
        try lock.withLock {
            guard var record = try loadOutboxLocked(eventId) else { return }
            record.state = state
            if state == .sending { record.attemptCount += 1 }
            record.lastErrorCode = errorCode
            try writeOutboxLocked(record)
        }
    }

    /// Commits the exact pairwise envelopes before the first network enqueue.
    /// A non-empty recipient set is immutable so retries cannot advance ratchets
    /// and accidentally replace the ciphertext for an existing event ID.
    func resolveOutboxRecipients(_ eventId: UUID, recipients: [ChatRecipient]) throws {
        try lock.withLock {
            guard var record = try loadOutboxLocked(eventId) else { throw EncryptedChatError.invalidEvent }
            let stored = recipients.map {
                StoredChatRecipient(aci: $0.aci, deviceId: $0.deviceId, envelope: $0.envelope)
            }
            if !record.recipients.isEmpty {
                guard record.recipients == stored else { throw EncryptedChatError.invalidEvent }
                return
            }
            record = StoredChatOutboxRecord(
                event: record.event, recipients: stored, expiresAt: record.expiresAt,
                state: .queued, attemptCount: record.attemptCount, lastErrorCode: nil
            )
            try writeOutboxLocked(record)
        }
    }

    func removeOutbox(_ eventId: UUID) throws {
        try lock.withLock { try removeOutboxLocked(eventId) }
    }

    func cancelSend(_ eventId: UUID) throws {
        try lock.withLock {
            try removeOutboxLocked(eventId)
            try removeEventLocked(eventId)
            try removeLocked(eventId)
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

    func partialAttachment(messageId: UUID, objectId: UUID) throws -> Data? {
        try lock.withLock {
            let url = partialObjectUrl(messageId, objectId)
            return FileManager.default.fileExists(atPath: url.path)
                ? try Data(contentsOf: url, options: [.mappedIfSafe]) : nil
        }
    }

    func cachePartialAttachment(_ ciphertext: Data, messageId: UUID, objectId: UUID) throws {
        guard !ciphertext.isEmpty, ciphertext.count <= EncryptedChatCodec.maximumAttachmentBytes + 64 else {
            throw EncryptedChatError.invalidAttachment
        }
        try lock.withLock {
            try protectedWrite(ciphertext, to: partialObjectUrl(messageId, objectId))
            _ = try prunePartialAttachmentsLocked(
                now: Date(), maximumBytes: min(maximumBytes, 100 * 1_024 * 1_024)
            )
        }
    }

    func clearPartialAttachment(messageId: UUID, objectId: UUID) throws {
        try lock.withLock {
            let url = partialObjectUrl(messageId, objectId)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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

    private func loadEventLocked(_ id: UUID) throws -> StoredChatEventRecord? {
        let url = eventMetadataUrl(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let clear = try AES.GCM.open(box, using: key, authenticating: eventAad(id))
        let record = try decoder.decode(StoredChatEventRecord.self, from: clear)
        guard record.event.eventId == id else { throw EncryptedChatError.invalidEvent }
        return record
    }

    private func loadOutboxLocked(_ id: UUID) throws -> StoredChatOutboxRecord? {
        let url = outboxUrl(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let clear = try AES.GCM.open(box, using: key, authenticating: outboxAad(id))
        let record = try decoder.decode(StoredChatOutboxRecord.self, from: clear)
        guard record.event.eventId == id else { throw EncryptedChatError.invalidEvent }
        return record
    }

    private func writeOutboxLocked(_ record: StoredChatOutboxRecord) throws {
        let clear = try encoder.encode(record)
        let box = try AES.GCM.seal(clear, using: key, authenticating: outboxAad(record.event.eventId))
        guard let combined = box.combined else { throw EncryptedChatError.invalidEvent }
        try protectedWrite(combined, to: outboxUrl(record.event.eventId))
    }

    private func pruneLocked(now: Date) throws {
        var records = try metadataUrls().compactMap { url -> StoredChatRecord? in
            let record = try loadLocked(id(from: url))
            if let record, record.expiresAt <= now { try removeLocked(record.message.messageId); return nil }
            return record
        }
        var eventRecords = try eventMetadataUrls().compactMap { url -> StoredChatEventRecord? in
            let record = try loadEventLocked(id(from: url, prefixCount: 6))
            if let record, record.expiresAt <= now { try removeEventLocked(record.event.eventId); return nil }
            return record
        }
        for url in try outboxUrls() {
            let id = try id(from: url, prefixCount: 7)
            if let record = try loadOutboxLocked(id), record.expiresAt <= now { try removeOutboxLocked(id) }
        }
        var total = records.reduce(Int64(0)) { partial, record in
            partial + storedBytesLocked(record.message.messageId)
        } + eventRecords.reduce(Int64(0)) { partial, record in
            partial + storedEventBytesLocked(record.event.eventId)
        }
        total += try prunePartialAttachmentsLocked(
            now: now, maximumBytes: max(0, maximumBytes - total)
        )
        let candidates = records.map { ($0.message.sentAt, $0.message.messageId, true) } +
            eventRecords.map { ($0.event.sentAt, $0.event.eventId, false) }
        for candidate in candidates.sorted(by: {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1.uuidString < $1.1.uuidString
        }) where total > maximumBytes {
            let size = candidate.2 ? storedBytesLocked(candidate.1) : storedEventBytesLocked(candidate.1)
            if candidate.2 { try removeLocked(candidate.1) } else { try removeEventLocked(candidate.1) }
            total -= size
        }
        records.removeAll()
        eventRecords.removeAll()
    }

    private func storedBytesLocked(_ id: UUID) -> Int64 {
        [metadataUrl(id), objectUrl(id)].reduce(Int64(0)) { partial, url in
            partial + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func storedEventBytesLocked(_ id: UUID) -> Int64 {
        let url = eventMetadataUrl(id)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func removeLocked(_ id: UUID) throws {
        for url in [metadataUrl(id), objectUrl(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let prefix = "partial-\(id.uuidString.lowercased())-"
        for url in try partialObjectUrls() where url.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prunePartialAttachmentsLocked(now: Date, maximumBytes: Int64) throws -> Int64 {
        let staleBefore = now.addingTimeInterval(-24 * 60 * 60)
        var entries: [(url: URL, modified: Date, size: Int64)] = []
        for url in try partialObjectUrls() {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values.contentModificationDate ?? .distantPast
            if modified < staleBefore {
                try FileManager.default.removeItem(at: url)
            } else {
                entries.append((url, modified, Int64(values.fileSize ?? 0)))
            }
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries.sorted(by: {
            if $0.modified != $1.modified { return $0.modified < $1.modified }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }) where total > maximumBytes {
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
        return total
    }

    private func partialObjectUrl(_ messageId: UUID, _ objectId: UUID) -> URL {
        root.appendingPathComponent(
            "partial-\(messageId.uuidString.lowercased())-\(objectId.uuidString.lowercased()).bin"
        )
    }

    private func removeEventLocked(_ id: UUID) throws {
        let url = eventMetadataUrl(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func removeOutboxLocked(_ id: UUID) throws {
        let url = outboxUrl(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
    private func eventMetadataUrls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("event-") && $0.pathExtension == "bin" }
    }
    private func outboxUrls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("outbox-") && $0.pathExtension == "bin" }
    }
    private func partialObjectUrls() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("partial-") && $0.pathExtension == "bin" }
    }
    private func id(from url: URL, prefixCount: Int = 8) throws -> UUID {
        guard let value = UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefixCount))) else {
            throw EncryptedChatError.invalidMessage
        }
        return value
    }
    private func metadataUrl(_ id: UUID) -> URL { root.appendingPathComponent("message-\(id.uuidString.lowercased()).bin") }
    private func eventMetadataUrl(_ id: UUID) -> URL { root.appendingPathComponent("event-\(id.uuidString.lowercased()).bin") }
    private func outboxUrl(_ id: UUID) -> URL { root.appendingPathComponent("outbox-\(id.uuidString.lowercased()).bin") }
    private func objectUrl(_ id: UUID) -> URL { root.appendingPathComponent("object-\(id.uuidString.lowercased()).bin") }
    private func aad(_ id: UUID) -> Data { Data("PTT-CHAT-LOCAL-V1/\(id.uuidString.lowercased())".utf8) }
    private func eventAad(_ id: UUID) -> Data { Data("PTT-CHAT-EVENT-LOCAL-V1/\(id.uuidString.lowercased())".utf8) }
    private func outboxAad(_ id: UUID) -> Data { Data("PTT-CHAT-OUTBOX-LOCAL-V1/\(id.uuidString.lowercased())".utf8) }
}
