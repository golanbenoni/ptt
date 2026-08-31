import CryptoKit
import Foundation
import LibSignalClient

public struct ChatConversationPreferences: Codable, Equatable, Sendable {
    public var isMuted: Bool
    public var isPinned: Bool
    public var isArchived: Bool

    public init(isMuted: Bool = false, isPinned: Bool = false, isArchived: Bool = false) {
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

public actor EncryptedChatClient {
    private let session: DeviceSession
    private let api: ControlApi
    private let crypto: PersistentPairwiseCrypto
    private let archive: SecureChatArchive
    private let signalStore: KeychainSignalProtocolStore
    private var injectedDeliveryFailures: Int

    public init(
        session: DeviceSession,
        signalStore: KeychainSignalProtocolStore,
        pairwiseCrypto: PersistentPairwiseCrypto? = nil,
        allowInsecureHttp: Bool = false,
        injectedDeliveryFailures: Int = 0
    ) throws {
        self.session = session
        self.signalStore = signalStore
        api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: allowInsecureHttp)
        if let pairwiseCrypto {
            crypto = pairwiseCrypto
        } else {
            crypto = try PersistentPairwiseCrypto(
                session: session, store: signalStore, allowInsecureHttp: allowInsecureHttp
            )
        }
        let accountNamespace = SHA256.hash(data: Data(session.aci.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        archive = try SecureChatArchive(namespace: "app.ptt.talk.chat.v1-\(accountNamespace)-\(session.deviceId)")
        self.injectedDeliveryFailures = max(0, injectedDeliveryFailures)
    }

    public func messages(channelId: UUID) throws -> [ChatMessage] { try archive.messages(channelId: channelId) }

    public func conversation(channelId: UUID) throws -> [ChatConversationMessage] {
        let pending = Dictionary(uniqueKeysWithValues: try archive.outbox().map { ($0.event.eventId, $0.state) })
        let starred = try starredMessageIds(channelId: channelId)
        return try archive.conversation(channelId: channelId, localAci: session.aci).map { item in
            var sendState: ChatSendState?
            if item.message.senderAci.caseInsensitiveCompare(session.aci) == .orderedSame {
                if let outbox = pending[item.message.messageId] {
                    switch outbox {
                    case .queued: sendState = .queued
                    case .sending: sendState = .sending
                    case .failed: sendState = .failed
                    }
                } else {
                    switch item.receipts.values.max() {
                    case .played?: sendState = .played
                    case .read?: sendState = .read
                    case .delivered?: sendState = .delivered
                    case nil: sendState = .sent
                    }
                }
            }
            return ChatConversationMessage(
                message: item.message, replyToMessageId: item.replyToMessageId,
                editedText: item.editedText, isDeleted: item.isDeleted,
                reactions: item.reactions, receipts: item.receipts,
                isUnread: item.isUnread, isPinned: item.isPinned,
                isStarred: starred.contains(item.message.messageId), sendState: sendState
            )
        }
    }

    public func unreadCount(channelId: UUID) throws -> Int {
        try archive.unreadCount(channelId: channelId, localAci: session.aci)
    }

    public func draft(channelId: UUID) throws -> String {
        guard let data = try signalStore.applicationState(draftKey(channelId)) else { return "" }
        guard let value = String(data: data, encoding: .utf8) else { throw EncryptedChatError.invalidMessage }
        return value
    }

    public func saveDraft(_ value: String, channelId: UUID) throws {
        let bounded = EncryptedChatCodec.boundedUTF8(value, maximumBytes: 4_096)
        try signalStore.putApplicationState(draftKey(channelId), value: Data(bounded.utf8))
    }

    public func preferences(channelId: UUID) throws -> ChatConversationPreferences {
        guard let data = try signalStore.applicationState(preferencesKey(channelId)) else { return .init() }
        return try JSONDecoder().decode(ChatConversationPreferences.self, from: data)
    }

    public func savePreferences(_ value: ChatConversationPreferences, channelId: UUID) throws {
        try signalStore.putApplicationState(preferencesKey(channelId), value: try JSONEncoder().encode(value))
    }

    public func setStarred(_ starred: Bool, messageId: UUID, channelId: UUID) throws {
        var values = try starredMessageIds(channelId: channelId)
        if starred { values.insert(messageId) } else { values.remove(messageId) }
        let encoded = values.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n")
        try signalStore.putApplicationState(starredKey(channelId), value: Data(encoded.utf8))
    }

    private func starredMessageIds(channelId: UUID) throws -> Set<UUID> {
        guard let data = try signalStore.applicationState(starredKey(channelId)),
              let value = String(data: data, encoding: .utf8) else { return [] }
        return Set(value.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    public func eraseLocalData() throws { try archive.erase() }

    private func draftKey(_ channelId: UUID) -> String {
        "chat-draft-v1-\(channelId.uuidString.lowercased())"
    }

    private func starredKey(_ channelId: UUID) -> String {
        "chat-starred-v1-\(channelId.uuidString.lowercased())"
    }

    private func preferencesKey(_ channelId: UUID) -> String {
        "chat-preferences-v1-\(channelId.uuidString.lowercased())"
    }

    @discardableResult
    public func sendText(_ text: String, replyTo: UUID? = nil, channel: ChannelSummary) async throws -> ChatMessage {
        try await sendMessage(
            kind: .text, text: text, attachment: nil, attachmentCiphertext: nil,
            replyTo: replyTo, channel: channel
        )
    }

    @discardableResult
    public func sendAttachment(
        data: Data,
        fileName: String,
        mimeType: String,
        kind: ChatContentKind,
        durationMs: Int32 = 0,
        waveform: Data = Data(),
        thumbnailData: Data? = nil,
        thumbnailMimeType: String = "image/jpeg",
        thumbnailWidth: UInt16 = 0,
        thumbnailHeight: UInt16 = 0,
        caption: String = "",
        channel: ChannelSummary,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws -> ChatMessage {
        guard kind != .text, let channelId = UUID(uuidString: channel.channelId) else {
            throw EncryptedChatError.invalidAttachment
        }
        let attachmentId = UUID()
        let sealed = try EncryptedChatCodec.sealAttachment(
            data, attachmentId: attachmentId, channelId: channelId,
            membershipEpoch: Int32(channel.membershipEpoch)
        )
        let boundedName = EncryptedChatCodec.boundedUTF8(fileName, maximumBytes: 255)
        let boundedMime = EncryptedChatCodec.boundedUTF8(mimeType, maximumBytes: 127)
        let thumbnailMetadata: ChatThumbnail?
        let thumbnailCiphertext: Data?
        if let thumbnailData {
            guard thumbnailWidth > 0, thumbnailHeight > 0 else {
                throw EncryptedChatError.invalidAttachment
            }
            let thumbnailId = UUID()
            let thumbnailSealed = try EncryptedChatCodec.sealThumbnail(
                thumbnailData, thumbnailId: thumbnailId, channelId: channelId,
                membershipEpoch: Int32(channel.membershipEpoch)
            )
            let thumbnailMime = EncryptedChatCodec.boundedUTF8(thumbnailMimeType, maximumBytes: 63)
            thumbnailMetadata = ChatThumbnail(
                thumbnailId: thumbnailId,
                mimeType: thumbnailMime.isEmpty ? "image/jpeg" : thumbnailMime,
                plaintextBytes: Int32(thumbnailData.count), width: thumbnailWidth, height: thumbnailHeight,
                key: thumbnailSealed.key, ciphertextSha256: thumbnailSealed.sha256
            )
            thumbnailCiphertext = thumbnailSealed.ciphertext
        } else {
            thumbnailMetadata = nil
            thumbnailCiphertext = nil
        }
        let attachment = ChatAttachment(
            attachmentId: attachmentId,
            fileName: boundedName.isEmpty ? "Attachment" : boundedName,
            mimeType: boundedMime.isEmpty ? "application/octet-stream" : boundedMime,
            plaintextBytes: Int64(data.count),
            durationMs: durationMs,
            waveform: waveform,
            thumbnail: thumbnailMetadata,
            key: sealed.key,
            ciphertextSha256: sealed.sha256
        )
        return try await sendMessage(
            kind: kind, text: caption, attachment: attachment,
            attachmentCiphertext: try EncryptedChatCodec.packAttachmentCiphertexts(
                attachment: sealed.ciphertext, thumbnail: thumbnailCiphertext
            ), channel: channel, onProgress: onProgress
        )
    }

    public func poll(channels: [ChannelSummary]) async throws -> Int {
        _ = await retryPending(channels: channels)
        let items = try await api.chatItems(session: session)
        guard !items.isEmpty else { return 0 }
        var acknowledged: [String] = []
        var accepted = 0
        var deliveredReceipts: [(UUID, ChannelSummary)] = []
        for item in items {
            guard let channel = channels.first(where: { $0.channelId.lowercased() == item.channelId.uuidString.lowercased() }),
                  channel.membershipEpoch == item.membershipEpoch else {
                acknowledged.append(item.itemId)
                continue
            }
            do {
                let devices = try await api.channelDevices(session: session, channelId: item.channelId.uuidString.lowercased())
                let opened = try await crypto.decryptDataEnvelope(item.envelope, allowedDevices: devices)
                let event = try EncryptedChatCodec.decodeEventOrLegacyMessage(
                    opened.plaintext, senderAci: opened.senderAci, senderDeviceId: opened.senderDeviceId
                )
                guard event.eventId == item.messageId, event.channelId == item.channelId,
                      event.membershipEpoch == item.membershipEpoch else {
                    throw EncryptedChatError.invalidMessage
                }
                let now = Date()
                guard event.sentAt <= now.addingTimeInterval(300),
                      event.sentAt >= now.addingTimeInterval(-TimeInterval((channel.retentionDays + 1) * 86_400))
                else { throw EncryptedChatError.invalidMessage }
                try archive.putEvent(
                    event,
                    expiresAt: event.sentAt.addingTimeInterval(TimeInterval(channel.retentionDays * 86_400))
                )
                if event.kind == .message,
                   event.senderAci.caseInsensitiveCompare(session.aci) != .orderedSame {
                    deliveredReceipts.append((event.eventId, channel))
                }
                acknowledged.append(item.itemId)
                accepted += 1
            } catch let error as EncryptedChatError
                where error == .invalidMessage || error == .invalidEvent || error == .invalidAttachment {
                acknowledged.append(item.itemId)
            } catch let error as SignalError {
                // A later message can be observed before the first prekey
                // message after a queue handoff. Leave it unacknowledged so a
                // subsequent poll can open it once the session exists.
                if case .sessionNotFound = error { continue }
                // Delivery is at-least-once. A ciphertext that advanced the
                // ratchet before the acknowledgement reached the server is an
                // authenticated replay, not a reason to abort every newer
                // item in the mailbox. Its event is already in the archive.
                if case .duplicatedMessage = error {
                    acknowledged.append(item.itemId)
                    continue
                }
                throw error
            }
        }
        if !acknowledged.isEmpty { _ = try await api.acknowledgeChat(session: session, itemIds: acknowledged) }
        for (messageId, channel) in deliveredReceipts {
            _ = try? await sendReceipt(.delivered, for: messageId, channel: channel)
        }
        return accepted
    }

    public func pendingSendCount() throws -> Int { try archive.outbox().count }

    @discardableResult
    public func retryPending(channels: [ChannelSummary]) async -> Int {
        guard let pending = try? archive.outbox() else { return 0 }
        var delivered = 0
        for item in pending {
            guard let channel = channels.first(where: {
                $0.channelId.lowercased() == item.event.channelId.uuidString.lowercased()
            }) else { continue }
            guard channel.membershipEpoch == item.event.membershipEpoch else {
                // Device linking, revocation, or membership changes rotate the
                // epoch. Never discover recipients for an event created under
                // an older epoch: that could expose queued history to a newly
                // authorized device.
                try? archive.markOutbox(
                    item.event.eventId, state: .failed,
                    errorCode: "membership_epoch_changed"
                )
                continue
            }
            do {
                try await deliver(item, channel: channel)
                delivered += 1
            } catch {
                try? archive.markOutbox(item.event.eventId, state: .failed, errorCode: "delivery_failed")
            }
        }
        return delivered
    }

    public func attachmentData(
        for message: ChatMessage,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws -> Data {
        guard let metadata = message.attachment else { throw EncryptedChatError.invalidAttachment }
        let cached = try archive.attachmentCiphertext(messageId: message.messageId)
        var bundle: (attachment: Data?, thumbnail: Data?) = try cached.map(
            EncryptedChatCodec.unpackAttachmentCiphertexts
        ) ?? (attachment: nil, thumbnail: nil)
        if bundle.attachment == nil {
            let downloaded = try await downloadAttachmentCiphertext(
                messageId: message.messageId, objectId: metadata.attachmentId,
                expectedBytes: Int(metadata.plaintextBytes) + 33,
                expectedSha256: metadata.ciphertextSha256, onProgress: onProgress
            )
            let plaintext = try EncryptedChatCodec.openAttachment(
                downloaded, metadata: metadata, channelId: message.channelId,
                membershipEpoch: message.membershipEpoch
            )
            bundle.attachment = downloaded
            try archive.cacheAttachment(
                EncryptedChatCodec.packAttachmentCiphertexts(
                    attachment: bundle.attachment, thumbnail: bundle.thumbnail
                ), messageId: message.messageId
            )
            try archive.clearPartialAttachment(
                messageId: message.messageId, objectId: metadata.attachmentId
            )
            return plaintext
        }
        return try EncryptedChatCodec.openAttachment(
            bundle.attachment!, metadata: metadata, channelId: message.channelId,
            membershipEpoch: message.membershipEpoch
        )
    }

    public func thumbnailData(
        for message: ChatMessage,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws -> Data {
        guard let thumbnail = message.attachment?.thumbnail else {
            throw EncryptedChatError.invalidAttachment
        }
        let cached = try archive.attachmentCiphertext(messageId: message.messageId)
        var bundle: (attachment: Data?, thumbnail: Data?) = try cached.map(
            EncryptedChatCodec.unpackAttachmentCiphertexts
        ) ?? (attachment: nil, thumbnail: nil)
        if bundle.thumbnail == nil {
            let downloaded = try await downloadAttachmentCiphertext(
                messageId: message.messageId, objectId: thumbnail.thumbnailId,
                expectedBytes: Int(thumbnail.plaintextBytes) + 33,
                expectedSha256: thumbnail.ciphertextSha256, onProgress: onProgress
            )
            let plaintext = try EncryptedChatCodec.openThumbnail(
                downloaded, metadata: thumbnail, channelId: message.channelId,
                membershipEpoch: message.membershipEpoch
            )
            bundle.thumbnail = downloaded
            try archive.cacheAttachment(
                EncryptedChatCodec.packAttachmentCiphertexts(
                    attachment: bundle.attachment, thumbnail: bundle.thumbnail
                ), messageId: message.messageId
            )
            try archive.clearPartialAttachment(
                messageId: message.messageId, objectId: thumbnail.thumbnailId
            )
            return plaintext
        }
        return try EncryptedChatCodec.openThumbnail(
            bundle.thumbnail!, metadata: thumbnail, channelId: message.channelId,
            membershipEpoch: message.membershipEpoch
        )
    }

    private func downloadAttachmentCiphertext(
        messageId: UUID,
        objectId: UUID,
        expectedBytes: Int,
        expectedSha256: Data,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)?
    ) async throws -> Data {
        guard expectedBytes > 0, expectedBytes <= EncryptedChatCodec.maximumAttachmentBytes + 64,
              expectedSha256.count == 32 else { throw EncryptedChatError.invalidAttachment }
        var ciphertext = try archive.partialAttachment(messageId: messageId, objectId: objectId) ?? Data()
        if ciphertext.count > expectedBytes {
            try archive.clearPartialAttachment(messageId: messageId, objectId: objectId)
            ciphertext.removeAll(keepingCapacity: false)
        }
        await onProgress?(ChatTransferProgress(completedBytes: ciphertext.count, totalBytes: expectedBytes))
        while ciphertext.count < expectedBytes {
            try Task.checkCancellation()
            let chunk = try await api.downloadChatAttachmentChunk(
                session: session, attachmentId: objectId, offset: ciphertext.count
            )
            guard chunk.totalBytes == expectedBytes, chunk.ciphertextSha256 == expectedSha256,
                  !chunk.bytes.isEmpty, ciphertext.count + chunk.bytes.count <= expectedBytes else {
                try? archive.clearPartialAttachment(messageId: messageId, objectId: objectId)
                throw EncryptedChatError.attachmentIntegrityFailed
            }
            ciphertext.append(chunk.bytes)
            try archive.cachePartialAttachment(ciphertext, messageId: messageId, objectId: objectId)
            await onProgress?(ChatTransferProgress(completedBytes: ciphertext.count, totalBytes: expectedBytes))
        }
        guard Data(SHA256.hash(data: ciphertext)) == expectedSha256 else {
            try? archive.clearPartialAttachment(messageId: messageId, objectId: objectId)
            throw EncryptedChatError.attachmentIntegrityFailed
        }
        return ciphertext
    }

    @discardableResult
    public func sendReceipt(
        _ kind: ChatEventKind,
        for messageId: UUID,
        channel: ChannelSummary
    ) async throws -> ChatEvent {
        guard kind == .delivered || kind == .read || kind == .played else {
            throw EncryptedChatError.invalidEvent
        }
        return try await sendMutation(kind, target: messageId, value: "", channel: channel)
    }

    @discardableResult
    public func sendReaction(_ value: String, for messageId: UUID, channel: ChannelSummary) async throws -> ChatEvent {
        try await sendMutation(.reaction, target: messageId, value: value, channel: channel)
    }

    @discardableResult
    public func removeReaction(for messageId: UUID, channel: ChannelSummary) async throws -> ChatEvent {
        try await sendMutation(.removeReaction, target: messageId, value: "", channel: channel)
    }

    @discardableResult
    public func editMessage(_ value: String, messageId: UUID, channel: ChannelSummary) async throws -> ChatEvent {
        try await sendMutation(.edit, target: messageId, value: value, channel: channel)
    }

    @discardableResult
    public func deleteMessage(_ messageId: UUID, channel: ChannelSummary) async throws -> ChatEvent {
        try await sendMutation(.delete, target: messageId, value: "", channel: channel)
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, messageId: UUID, channel: ChannelSummary) async throws -> ChatEvent {
        try await sendMutation(pinned ? .pin : .unpin, target: messageId, value: "", channel: channel)
    }

    private func sendMutation(
        _ kind: ChatEventKind,
        target: UUID,
        value: String,
        channel: ChannelSummary
    ) async throws -> ChatEvent {
        guard let channelId = UUID(uuidString: channel.channelId) else { throw EncryptedChatError.invalidEvent }
        let event = ChatEvent(
            eventId: UUID(), channelId: channelId, membershipEpoch: Int32(channel.membershipEpoch),
            sentAt: Date(), senderAci: session.aci.lowercased(), senderDeviceId: session.deviceId,
            kind: kind, targetMessageId: target, value: value
        )
        try await enqueue(event: event, attachmentCiphertext: nil, channel: channel)
        return event
    }

    private func sendMessage(
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment?,
        attachmentCiphertext: Data?,
        replyTo: UUID? = nil,
        channel: ChannelSummary,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws -> ChatMessage {
        guard let channelId = UUID(uuidString: channel.channelId) else { throw EncryptedChatError.invalidMessage }
        let message = ChatMessage(
            messageId: UUID(), channelId: channelId, membershipEpoch: Int32(channel.membershipEpoch),
            sentAt: Date(), senderAci: session.aci.lowercased(), senderDeviceId: session.deviceId,
            kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachment: attachment
        )
        try await enqueue(
            event: .message(message, replyTo: replyTo),
            attachmentCiphertext: attachmentCiphertext, channel: channel, onProgress: onProgress
        )
        return message
    }

    private func enqueue(
        event: ChatEvent,
        attachmentCiphertext: Data?,
        channel: ChannelSummary,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws {
        _ = try EncryptedChatCodec.encodeEvent(event)
        let expiresAt = event.sentAt.addingTimeInterval(TimeInterval(channel.retentionDays * 86_400))
        // Local event, attachment ciphertext, and an unresolved outbox entry are
        // durable before recipient discovery or any other network operation.
        try archive.putEvent(event, expiresAt: expiresAt, attachmentCiphertext: attachmentCiphertext)
        try archive.putOutbox(event: event, recipients: [], expiresAt: expiresAt)
        guard let item = try archive.outbox().first(where: { $0.event.eventId == event.eventId }) else {
            throw EncryptedChatError.invalidEvent
        }
        do {
            try await deliver(item, channel: channel, onProgress: onProgress)
        } catch {
            if error is CancellationError {
                try? archive.cancelSend(event.eventId)
            } else {
                try? archive.markOutbox(event.eventId, state: .failed, errorCode: "delivery_failed")
            }
            throw error
        }
    }

    private func deliver(
        _ unresolved: ChatOutboxItem,
        channel: ChannelSummary,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws {
        guard unresolved.event.channelId.uuidString.caseInsensitiveCompare(channel.channelId) == .orderedSame,
              unresolved.event.membershipEpoch == channel.membershipEpoch else {
            throw EncryptedChatError.invalidEvent
        }
        if injectedDeliveryFailures > 0 {
            injectedDeliveryFailures -= 1
            throw EncryptedChatError.deliveryInterrupted
        }
        var item = unresolved
        if item.recipients.isEmpty {
            let plaintext = try EncryptedChatCodec.encodeEvent(item.event)
            let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
            var recipients: [ChatRecipient] = []
            for device in devices where device.aci != session.aci || device.deviceId != session.deviceId {
                recipients.append(ChatRecipient(
                    aci: device.aci, deviceId: device.deviceId,
                    envelope: try await crypto.encryptDataFor(device: device, plaintext: plaintext)
                ))
            }
            // No other authorized device is a successful local-only send.
            guard !recipients.isEmpty else {
                try archive.removeOutbox(item.event.eventId)
                return
            }
            try archive.resolveOutboxRecipients(item.event.eventId, recipients: recipients)
            guard let resolved = try archive.outbox().first(where: { $0.event.eventId == item.event.eventId }) else {
                throw EncryptedChatError.invalidEvent
            }
            item = resolved
        }
        try archive.markOutbox(item.event.eventId, state: .sending)
        if let message = item.event.message, let attachment = message.attachment,
           let cached = try archive.attachmentCiphertext(messageId: message.messageId) {
            let ciphertexts = try EncryptedChatCodec.unpackAttachmentCiphertexts(cached)
            guard let ciphertext = ciphertexts.attachment else {
                throw EncryptedChatError.invalidAttachment
            }
            let primaryBytes = ciphertext.count
            let totalBytes = primaryBytes + (ciphertexts.thumbnail?.count ?? 0)
            _ = try await api.uploadChatAttachment(
                session: session, attachmentId: attachment.attachmentId, channelId: item.event.channelId,
                membershipEpoch: channel.membershipEpoch, ciphertext: ciphertext,
                ciphertextSha256: attachment.ciphertextSha256,
                onProgress: { progress in
                    await onProgress?(ChatTransferProgress(
                        completedBytes: progress.completedBytes, totalBytes: totalBytes
                    ))
                }
            )
            if let thumbnail = attachment.thumbnail {
                guard let ciphertext = ciphertexts.thumbnail else {
                    throw EncryptedChatError.invalidAttachment
                }
                _ = try await api.uploadChatAttachment(
                    session: session, attachmentId: thumbnail.thumbnailId, channelId: item.event.channelId,
                    membershipEpoch: channel.membershipEpoch, ciphertext: ciphertext,
                    ciphertextSha256: thumbnail.ciphertextSha256,
                    onProgress: { progress in
                        await onProgress?(ChatTransferProgress(
                            completedBytes: primaryBytes + progress.completedBytes,
                            totalBytes: totalBytes
                        ))
                    }
                )
            }
        }
        _ = try await api.enqueueChat(
            session: session, messageId: item.event.eventId, channelId: item.event.channelId,
            membershipEpoch: channel.membershipEpoch, recipients: item.recipients, expiresAt: item.expiresAt
        )
        try archive.removeOutbox(item.event.eventId)
    }
}
