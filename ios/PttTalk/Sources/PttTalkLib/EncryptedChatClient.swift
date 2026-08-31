import CryptoKit
import Foundation

public actor EncryptedChatClient {
    private let session: DeviceSession
    private let api: ControlApi
    private let crypto: PersistentPairwiseCrypto
    private let archive: SecureChatArchive

    public init(
        session: DeviceSession,
        signalStore: KeychainSignalProtocolStore,
        pairwiseCrypto: PersistentPairwiseCrypto? = nil,
        allowInsecureHttp: Bool = false
    ) throws {
        self.session = session
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
    }

    public func messages(channelId: UUID) throws -> [ChatMessage] { try archive.messages(channelId: channelId) }

    public func eraseLocalData() throws { try archive.erase() }

    @discardableResult
    public func sendText(_ text: String, channel: ChannelSummary) async throws -> ChatMessage {
        try await send(kind: .text, text: text, attachment: nil, attachmentCiphertext: nil, channel: channel)
    }

    @discardableResult
    public func sendAttachment(
        data: Data,
        fileName: String,
        mimeType: String,
        kind: ChatContentKind,
        durationMs: Int32 = 0,
        caption: String = "",
        channel: ChannelSummary
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
        let attachment = ChatAttachment(
            attachmentId: attachmentId,
            fileName: boundedName.isEmpty ? "Attachment" : boundedName,
            mimeType: boundedMime.isEmpty ? "application/octet-stream" : boundedMime,
            plaintextBytes: Int64(data.count),
            durationMs: durationMs,
            key: sealed.key,
            ciphertextSha256: sealed.sha256
        )
        _ = try await api.uploadChatAttachment(
            session: session, attachmentId: attachmentId, channelId: channelId,
            membershipEpoch: channel.membershipEpoch, ciphertext: sealed.ciphertext,
            ciphertextSha256: sealed.sha256
        )
        return try await send(
            kind: kind, text: caption, attachment: attachment,
            attachmentCiphertext: sealed.ciphertext, channel: channel
        )
    }

    public func poll(channels: [ChannelSummary]) async throws -> Int {
        let items = try await api.chatItems(session: session)
        guard !items.isEmpty else { return 0 }
        var acknowledged: [String] = []
        var accepted = 0
        for item in items {
            guard let channel = channels.first(where: { $0.channelId.lowercased() == item.channelId.uuidString.lowercased() }),
                  channel.membershipEpoch == item.membershipEpoch else {
                acknowledged.append(item.itemId)
                continue
            }
            do {
                let devices = try await api.channelDevices(session: session, channelId: item.channelId.uuidString.lowercased())
                let opened = try await crypto.decryptDataEnvelope(item.envelope, allowedDevices: devices)
                let message = try EncryptedChatCodec.decode(
                    opened.plaintext, senderAci: opened.senderAci, senderDeviceId: opened.senderDeviceId
                )
                guard message.messageId == item.messageId, message.channelId == item.channelId,
                      message.membershipEpoch == item.membershipEpoch else {
                    throw EncryptedChatError.invalidMessage
                }
                let now = Date()
                guard message.sentAt <= now.addingTimeInterval(300),
                      message.sentAt >= now.addingTimeInterval(-TimeInterval((channel.retentionDays + 1) * 86_400))
                else { throw EncryptedChatError.invalidMessage }
                try archive.put(
                    message,
                    expiresAt: message.sentAt.addingTimeInterval(TimeInterval(channel.retentionDays * 86_400))
                )
                acknowledged.append(item.itemId)
                accepted += 1
            } catch let error as EncryptedChatError where error == .invalidMessage || error == .invalidAttachment {
                acknowledged.append(item.itemId)
            }
        }
        if !acknowledged.isEmpty { _ = try await api.acknowledgeChat(session: session, itemIds: acknowledged) }
        return accepted
    }

    public func attachmentData(for message: ChatMessage) async throws -> Data {
        guard let metadata = message.attachment else { throw EncryptedChatError.invalidAttachment }
        let ciphertext: Data
        if let cached = try archive.attachmentCiphertext(messageId: message.messageId) {
            ciphertext = cached
        } else {
            ciphertext = try await api.downloadChatAttachment(session: session, attachmentId: metadata.attachmentId)
            try archive.cacheAttachment(ciphertext, messageId: message.messageId)
        }
        return try EncryptedChatCodec.openAttachment(
            ciphertext, metadata: metadata, channelId: message.channelId,
            membershipEpoch: message.membershipEpoch
        )
    }

    private func send(
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment?,
        attachmentCiphertext: Data?,
        channel: ChannelSummary
    ) async throws -> ChatMessage {
        guard let channelId = UUID(uuidString: channel.channelId) else { throw EncryptedChatError.invalidMessage }
        let devices = try await api.channelDevices(session: session, channelId: channel.channelId)
        let message = ChatMessage(
            messageId: UUID(), channelId: channelId, membershipEpoch: Int32(channel.membershipEpoch),
            sentAt: Date(), senderAci: session.aci, senderDeviceId: session.deviceId,
            kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachment: attachment
        )
        let plaintext = try EncryptedChatCodec.encode(message)
        var recipients: [ChatRecipient] = []
        for device in devices where device.aci != session.aci || device.deviceId != session.deviceId {
            recipients.append(ChatRecipient(
                aci: device.aci, deviceId: device.deviceId,
                envelope: try await crypto.encryptFor(device: device, plaintext: plaintext)
            ))
        }
        let expiresAt = message.sentAt.addingTimeInterval(TimeInterval(channel.retentionDays * 86_400))
        if !recipients.isEmpty {
            _ = try await api.enqueueChat(
                session: session, messageId: message.messageId, channelId: channelId,
                membershipEpoch: channel.membershipEpoch, recipients: recipients, expiresAt: expiresAt
            )
        }
        try archive.put(message, expiresAt: expiresAt, attachmentCiphertext: attachmentCiphertext)
        return message
    }
}
