import CryptoKit
import Foundation

public struct DeviceSession: Codable, Equatable, Sendable {
    public let serverUrl: String
    public let aci: String
    public let deviceId: Int
    public let mailboxId: String
    public let accessToken: String

    public init(serverUrl: String, aci: String, deviceId: Int, mailboxId: String, accessToken: String) {
        self.serverUrl = serverUrl
        self.aci = aci
        self.deviceId = deviceId
        self.mailboxId = mailboxId
        self.accessToken = accessToken
    }
}

public struct ChannelSummary: Codable, Equatable, Identifiable, Sendable {
    public let channelId: String
    public let displayName: String
    public let kind: String
    public let distributionId: String
    public let membershipEpoch: Int
    public let retentionDays: Int
    public let role: String
    public var id: String { channelId }

    public init(
        channelId: String,
        displayName: String,
        kind: String,
        distributionId: String,
        membershipEpoch: Int,
        retentionDays: Int,
        role: String
    ) {
        self.channelId = channelId
        self.displayName = displayName
        self.kind = kind
        self.distributionId = distributionId
        self.membershipEpoch = membershipEpoch
        self.retentionDays = retentionDays
        self.role = role
    }
}

public struct ChannelDevice: Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
    public let mailboxId: String
    public let identityKey: Data
    public let role: String
}

public struct RelayCredential: Equatable, Sendable {
    public let relayAddress: String
    public let ticket: String
    public let demuxToken: Data
    public let senderDemux: UInt32
    public let expiresAt: Date
}

public struct FloorGrant: Equatable, Sendable {
    public let granted: Bool
    public let requestToken: String
    public let grantedTotMs: Int
    public let reason: String?
}

public struct DeviceSummary: Equatable, Sendable {
    public let deviceId: Int
    public let mailboxId: String
    public let displayName: String
    public let status: String

    public init(deviceId: Int, mailboxId: String, displayName: String, status: String) {
        self.deviceId = deviceId
        self.mailboxId = mailboxId
        self.displayName = displayName
        self.status = status
    }
}

public struct DeviceLinkStart: Equatable, Sendable {
    public let requestId: String
    public let linkCode: String
}

public struct AdminConsoleHandoff: Equatable, Sendable {
    public let adminUrl: URL
    public let handoffCode: String
    public let expiresAt: Date
}

public struct PendingDeviceLink: Codable, Equatable, Sendable {
    public let serverUrl: String
    public let requestId: String
    public let aci: String
    public let deviceId: Int
    public let mailboxId: String
    public let claimToken: String
}

public struct PendingRecovery: Codable, Equatable, Sendable {
    public let serverUrl: String
    public let requestId: String
    public let claimToken: String

    public init(serverUrl: String, requestId: String, claimToken: String) {
        self.serverUrl = serverUrl
        self.requestId = requestId
        self.claimToken = claimToken
    }
}

public struct RecoveryClaim: Equatable, Sendable {
    public let requestId: String
    public let claimToken: String
    public let status: String
}

public struct RecoveryStatus: Equatable, Sendable {
    public let status: String
    public let aci: String?
    public let deviceId: Int?
    public let mailboxId: String?
    public let accessToken: String?
}

public struct OneTimePreKeyUpload: Equatable, Sendable {
    public let kind: String
    public let keyId: UInt32
    public let publicKey: Data

    public init(kind: String, keyId: UInt32, publicKey: Data) {
        self.kind = kind
        self.keyId = keyId
        self.publicKey = publicKey
    }
}

public struct FetchedPreKey: Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
    public let opaqueBundle: Data
    public let oneTimePreKeys: [OneTimePreKeyUpload]
}

public struct MailboxRecipient: Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
    public let envelope: Data
}

public struct MailboxItem: Equatable, Sendable {
    public let itemId: String
    public let messageId: String
    public let envelope: Data
}

public struct ChatRecipient: Equatable, Sendable {
    public let aci: String
    public let deviceId: Int
    public let envelope: Data

    public init(aci: String, deviceId: Int, envelope: Data) {
        self.aci = aci
        self.deviceId = deviceId
        self.envelope = envelope
    }
}

public struct ChatQueueItem: Equatable, Sendable {
    public let itemId: String
    public let messageId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int
    public let envelope: Data
}

public struct ChatAttachmentUpload: Equatable, Sendable {
    public let attachmentId: UUID
    public let ciphertextBytes: Int
    public let ciphertextSha256: Data
    public let expiresAt: Date
}

public struct ChatTransferProgress: Equatable, Sendable {
    public let completedBytes: Int
    public let totalBytes: Int

    public init(completedBytes: Int, totalBytes: Int) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public struct ChatAttachmentDownloadChunk: Equatable, Sendable {
    public let bytes: Data
    public let offset: Int
    public let totalBytes: Int
    public let ciphertextSha256: Data
}

struct ServerProtocolCompatibility: Equatable, Sendable {
    let protocolMajor: Int
    let protocolMinor: Int
    let minimumClientMajor: Int
    let minimumClientMinor: Int
    let capabilities: Set<String>
}

enum ProductProtocolContract {
    static let major = 1
    static let minor = 1
    static let requiredCapabilities: Set<String> = [
        "chat-attachments-v1",
        "chat-encrypted-thumbnails-v1",
        "chat-resumable-transfers-v1",
        "media-tls-v1",
        "push-wake-v1",
    ]

    static func validate(_ value: [String: Any]) throws -> ServerProtocolCompatibility {
        guard let protocolMajor = value["protocolMajor"] as? Int,
              let protocolMinor = value["protocolMinor"] as? Int,
              let minimumClientMajor = value["minimumClientMajor"] as? Int,
              let minimumClientMinor = value["minimumClientMinor"] as? Int,
              let capabilityValues = value["capabilities"] as? [String] else {
            throw ControlApiError.invalidResponse
        }
        let compatibility = ServerProtocolCompatibility(
            protocolMajor: protocolMajor, protocolMinor: protocolMinor,
            minimumClientMajor: minimumClientMajor, minimumClientMinor: minimumClientMinor,
            capabilities: Set(capabilityValues)
        )
        guard compatibility.protocolMajor == major, compatibility.protocolMinor >= minor else {
            throw ControlApiError.server(status: 426, code: "SERVER_UPGRADE_REQUIRED")
        }
        guard compatibility.minimumClientMajor == major,
              compatibility.minimumClientMinor <= minor else {
            throw ControlApiError.server(status: 426, code: "CLIENT_UPGRADE_REQUIRED")
        }
        guard compatibility.capabilities.isSuperset(of: requiredCapabilities) else {
            throw ControlApiError.server(status: 426, code: "SERVER_CAPABILITY_REQUIRED")
        }
        return compatibility
    }
}

private actor ServerCompatibilityCache {
    static let shared = ServerCompatibilityCache()
    private var values: [String: (value: ServerProtocolCompatibility, expiresAt: Date)] = [:]

    func value(for server: String, now: Date = Date()) -> ServerProtocolCompatibility? {
        guard let cached = values[server], cached.expiresAt > now else {
            values.removeValue(forKey: server)
            return nil
        }
        return cached.value
    }

    func store(_ value: ServerProtocolCompatibility, for server: String, now: Date = Date()) {
        values[server] = (value, now.addingTimeInterval(5 * 60))
    }
}

public struct HistoryMetadata: Equatable, Identifiable, Sendable {
    public let objectId: UUID
    public let talkId: UUID
    public let channelId: UUID
    public let membershipEpoch: Int
    public let mediaKid: UInt64
    public let startedAt: Date
    public let durationMs: Int
    public let expiresAt: Date
    public let ciphertextBytes: Int
    public var id: UUID { objectId }
}

public struct DownloadedHistory: Equatable, Sendable {
    public let metadata: HistoryMetadata
    public let ciphertext: Data
}

public final class ControlApi: @unchecked Sendable {
    public let baseUrl: URL
    private let urlSession: URLSession

    public init(serverUrl: String, allowInsecureHttp: Bool = false, urlSession: URLSession = .shared) throws {
        let normalized = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw ControlApiError.invalidServerUrl
        }
        guard scheme == "https" || (allowInsecureHttp && scheme == "http") else {
            throw ControlApiError.insecureServerUrl
        }
        self.baseUrl = url
        self.urlSession = urlSession
    }

    public func requestMagicLink(email: String, invitationCode: String) async throws {
        _ = try await request(path: "/v1/auth/magic-link/request", body: [
            "email": email,
            "invitationCode": invitationCode,
        ])
    }

    public func consumeMagicLink(
        token: String,
        deviceName: String,
        identityKey: Data,
        resumeSecret: Data
    ) async throws -> DeviceSession {
        let value = try dictionary(await request(path: "/v1/auth/magic-link/consume", body: [
            "token": token,
            "deviceName": deviceName,
            "identityKey": identityKey.base64Url,
            "resumeSecret": resumeSecret.base64Url,
        ]))
        return try session(value)
    }

    public func requestRecovery(email: String) async throws {
        _ = try await request(path: "/v1/auth/recovery/request", body: ["email": email])
    }

    public func consumeRecovery(token: String, deviceName: String, identityKey: Data) async throws -> RecoveryClaim {
        let value = try dictionary(await request(path: "/v1/auth/recovery/consume", body: [
            "token": token,
            "deviceName": deviceName,
            "identityKey": identityKey.base64Url,
        ]))
        return try RecoveryClaim(
            requestId: string(value, "requestId"),
            claimToken: string(value, "claimToken"),
            status: string(value, "status")
        )
    }

    public func recoveryStatus(_ pending: PendingRecovery) async throws -> RecoveryStatus {
        let value = try dictionary(await request(path: "/v1/auth/recovery/status", body: [
            "requestId": pending.requestId,
            "claimToken": pending.claimToken,
        ]))
        return RecoveryStatus(
            status: try string(value, "status"),
            aci: value["aci"] as? String,
            deviceId: number(value, "deviceId")?.intValue,
            mailboxId: value["mailboxId"] as? String,
            accessToken: value["accessToken"] as? String
        )
    }

    public func channels(session: DeviceSession) async throws -> [ChannelSummary] {
        try array(await request(path: "/v1/channels", method: "GET", accessToken: session.accessToken)).map { item in
            let value = try dictionary(item)
            return ChannelSummary(
                channelId: try string(value, "channelId"),
                displayName: try string(value, "displayName"),
                kind: try string(value, "kind"),
                distributionId: try string(value, "distributionId"),
                membershipEpoch: try integer(value, "membershipEpoch"),
                retentionDays: try integer(value, "retentionDays"),
                role: try string(value, "role")
            )
        }
    }

    public func channelDevices(session: DeviceSession, channelId: String) async throws -> [ChannelDevice] {
        try array(await request(
            path: "/v1/channels/\(pathComponent(channelId))/devices",
            method: "GET",
            accessToken: session.accessToken
        )).map { item in
            let value = try dictionary(item)
            return ChannelDevice(
                aci: try string(value, "aci"),
                deviceId: try integer(value, "deviceId"),
                mailboxId: try string(value, "mailboxId"),
                identityKey: try Data(base64Url: string(value, "identityKey")),
                role: try string(value, "role")
            )
        }
    }

    public func devices(session: DeviceSession) async throws -> [DeviceSummary] {
        try array(await request(path: "/v1/devices", method: "GET", accessToken: session.accessToken)).map { item in
            let value = try dictionary(item)
            return DeviceSummary(
                deviceId: try integer(value, "deviceId"),
                mailboxId: try string(value, "mailboxId"),
                displayName: try string(value, "displayName"),
                status: try string(value, "status")
            )
        }
    }

    public func revokeThisDevice(session: DeviceSession) async throws {
        try await revokeDevice(session: session, deviceId: session.deviceId)
    }

    public func revokeDevice(session: DeviceSession, deviceId: Int) async throws {
        guard (1...2).contains(deviceId) else { throw ControlApiError.invalidRequest }
        _ = try await request(
            path: "/v1/devices/revoke",
            body: ["deviceId": deviceId],
            accessToken: session.accessToken
        )
    }

    public func deleteAccount(session: DeviceSession) async throws {
        _ = try await request(
            path: "/v1/account/delete",
            body: ["confirmation": "DELETE"],
            accessToken: session.accessToken
        )
    }

    public func startDeviceLink(session: DeviceSession) async throws -> DeviceLinkStart {
        let value = try dictionary(await request(
            path: "/v1/devices/link/start",
            body: [:],
            accessToken: session.accessToken
        ))
        return try DeviceLinkStart(requestId: string(value, "requestId"), linkCode: string(value, "linkCode"))
    }

    public func startAdminConsoleSession(session: DeviceSession) async throws -> AdminConsoleHandoff {
        let value = try dictionary(await request(
            path: "/v1/admin/session/start",
            body: [:],
            accessToken: session.accessToken
        ))
        guard let adminUrl = URL(string: try string(value, "adminUrl")),
              let expiresAt = parseIso8601Date(try string(value, "expiresAt")) else {
            throw ControlApiError.invalidResponse
        }
        return AdminConsoleHandoff(
            adminUrl: adminUrl,
            handoffCode: try string(value, "handoffCode"),
            expiresAt: expiresAt
        )
    }

    public func claimDeviceLink(
        serverUrl: String,
        requestId: String,
        linkCode: String,
        deviceName: String,
        identityKey: Data
    ) async throws -> PendingDeviceLink {
        let value = try dictionary(await request(path: "/v1/devices/link/claim", body: [
            "requestId": requestId,
            "linkCode": linkCode,
            "deviceName": deviceName,
            "identityKey": identityKey.base64Url,
        ]))
        return try PendingDeviceLink(
            serverUrl: serverUrl,
            requestId: requestId,
            aci: string(value, "aci"),
            deviceId: integer(value, "deviceId"),
            mailboxId: string(value, "mailboxId"),
            claimToken: string(value, "claimToken")
        )
    }

    public func approveDeviceLink(session: DeviceSession, requestId: String) async throws {
        _ = try await request(
            path: "/v1/devices/link/approve",
            body: ["requestId": requestId],
            accessToken: session.accessToken
        )
    }

    public func deviceLinkStatus(_ pending: PendingDeviceLink) async throws -> DeviceSession? {
        let value = try dictionary(await request(
            path: "/v1/devices/link/status",
            body: ["claimToken": pending.claimToken]
        ))
        guard (value["status"] as? String) == "active", let token = value["accessToken"] as? String else { return nil }
        return DeviceSession(
            serverUrl: pending.serverUrl,
            aci: try string(value, "aci"),
            deviceId: try integer(value, "deviceId"),
            mailboxId: try string(value, "mailboxId"),
            accessToken: token
        )
    }

    public func relayCredential(session: DeviceSession, channelId: String) async throws -> RelayCredential {
        let value = try dictionary(await request(
            path: "/v1/relay/credentials",
            body: ["channelId": channelId],
            accessToken: session.accessToken
        ))
        let demux64 = try unsignedInteger(value, "senderDemux")
        guard demux64 > 0, demux64 <= UInt64(UInt32.max) else { throw ControlApiError.invalidResponse }
        guard let expiresAt = parseIso8601Date(try string(value, "expiresAt")) else {
            throw ControlApiError.invalidResponse
        }
        return RelayCredential(
            relayAddress: try string(value, "relayAddress"),
            ticket: try string(value, "ticket"),
            demuxToken: try Data(base64Url: string(value, "demuxToken")),
            senderDemux: UInt32(demux64),
            expiresAt: expiresAt
        )
    }

    public func requestFloor(
        session: DeviceSession,
        channel: ChannelSummary,
        relay: RelayCredential,
        requestToken: String = Data.random(count: 16).base64Url,
        requestedTotMs: Int = 30_000,
        sos: Bool = false
    ) async throws -> FloorGrant {
        let value = try dictionary(await request(path: "/v1/floor/request", body: [
            "channelId": channel.channelId,
            "requestToken": requestToken,
            "senderDemux": UInt64(relay.senderDemux),
            "membershipEpoch": channel.membershipEpoch,
            "requestedTotMs": requestedTotMs,
            "sos": sos,
        ], accessToken: session.accessToken))
        return FloorGrant(
            granted: try boolean(value, "granted"),
            requestToken: try string(value, "requestToken"),
            grantedTotMs: try integer(value, "grantedTotMs"),
            reason: value["reason"] as? String
        )
    }

    public func releaseFloor(session: DeviceSession, channelId: String, requestToken: String) async throws {
        _ = try await request(path: "/v1/floor/release", body: [
            "channelId": channelId,
            "requestToken": requestToken,
        ], accessToken: session.accessToken)
    }

    public func supportsCapability(_ capability: String) async throws -> Bool {
        try await ensureCompatible().capabilities.contains(capability)
    }

    public func uploadPreKeys(
        session: DeviceSession,
        opaqueBundle: Data,
        oneTimePreKeys: [OneTimePreKeyUpload]
    ) async throws {
        let keys: [[String: Any]] = oneTimePreKeys.map { key in
            ["kind": key.kind, "keyId": key.keyId, "publicKey": key.publicKey.base64Url]
        }
        _ = try await request(path: "/v1/prekeys/upload", body: [
            "opaqueBundle": opaqueBundle.base64Url,
            "oneTimePrekeys": keys,
        ], accessToken: session.accessToken)
    }

    public func fetchPreKeys(session: DeviceSession, devices: [(String, Int)]) async throws -> [FetchedPreKey] {
        guard !devices.isEmpty else { throw ControlApiError.invalidRequest }
        let refs: [[String: Any]] = devices.map { ["aci": $0.0, "deviceId": $0.1] }
        return try array(await request(
            path: "/v1/prekeys/fetch",
            body: ["devices": refs],
            accessToken: session.accessToken
        )).map { item in
            let value = try dictionary(item)
            let keys = try array(value["oneTimePrekeys"] as Any).map { keyItem -> OneTimePreKeyUpload in
                let key = try dictionary(keyItem)
                let id = try unsignedInteger(key, "keyId")
                guard id <= UInt64(UInt32.max) else { throw ControlApiError.invalidResponse }
                return try OneTimePreKeyUpload(
                    kind: string(key, "kind"),
                    keyId: UInt32(id),
                    publicKey: Data(base64Url: string(key, "publicKey"))
                )
            }
            return try FetchedPreKey(
                aci: string(value, "aci"),
                deviceId: integer(value, "deviceId"),
                opaqueBundle: Data(base64Url: string(value, "opaqueBundle")),
                oneTimePreKeys: keys
            )
        }
    }

    public func enqueueMailbox(
        session: DeviceSession,
        messageId: String,
        recipients: [MailboxRecipient],
        expiresAt: Date
    ) async throws -> Int {
        let rows: [[String: Any]] = recipients.map {
            ["aci": $0.aci, "deviceId": $0.deviceId, "envelope": $0.envelope.base64Url]
        }
        let value = try dictionary(await request(path: "/v1/mailbox/envelopes", body: [
            "messageId": messageId,
            "recipients": rows,
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
        ], accessToken: session.accessToken))
        return try integer(value, "acceptedRecipients")
    }

    public func mailboxItems(session: DeviceSession, limit: Int = 100) async throws -> [MailboxItem] {
        guard (1...100).contains(limit) else { throw ControlApiError.invalidRequest }
        return try array(await request(
            path: "/v1/mailbox/items?limit=\(limit)",
            method: "GET",
            accessToken: session.accessToken
        )).map { item in
            let value = try dictionary(item)
            return try MailboxItem(
                itemId: string(value, "itemId"),
                messageId: string(value, "messageId"),
                envelope: Data(base64Url: string(value, "envelope"))
            )
        }
    }

    public func acknowledgeMailbox(session: DeviceSession, itemIds: [String]) async throws -> Int {
        guard !itemIds.isEmpty else { throw ControlApiError.invalidRequest }
        let value = try dictionary(await request(
            path: "/v1/mailbox/ack",
            body: ["itemIds": itemIds],
            accessToken: session.accessToken
        ))
        return try integer(value, "acknowledged")
    }

    public func enqueueChat(
        session: DeviceSession,
        messageId: UUID,
        channelId: UUID,
        membershipEpoch: Int,
        recipients: [ChatRecipient],
        expiresAt: Date
    ) async throws -> Int {
        guard membershipEpoch > 0, !recipients.isEmpty else { throw ControlApiError.invalidRequest }
        let rows: [[String: Any]] = recipients.map {
            ["aci": $0.aci, "deviceId": $0.deviceId, "envelope": $0.envelope.base64Url]
        }
        let value = try dictionary(await request(path: "/v1/chat/messages", body: [
            "messageId": messageId.uuidString.lowercased(),
            "channelId": channelId.uuidString.lowercased(),
            "membershipEpoch": membershipEpoch,
            "recipients": rows,
            "expiresAt": iso8601String(expiresAt),
        ], accessToken: session.accessToken))
        return try integer(value, "acceptedRecipients")
    }

    public func chatItems(session: DeviceSession, limit: Int = 100) async throws -> [ChatQueueItem] {
        guard (1...100).contains(limit) else { throw ControlApiError.invalidRequest }
        return try array(await request(
            path: "/v1/chat/messages?limit=\(limit)", method: "GET", accessToken: session.accessToken
        )).map { item in
            let value = try dictionary(item)
            guard let messageId = UUID(uuidString: try string(value, "messageId")),
                  let channelId = UUID(uuidString: try string(value, "channelId")) else {
                throw ControlApiError.invalidResponse
            }
            return try ChatQueueItem(
                itemId: string(value, "itemId"),
                messageId: messageId,
                channelId: channelId,
                membershipEpoch: integer(value, "membershipEpoch"),
                envelope: Data(base64Url: string(value, "envelope"))
            )
        }
    }

    public func acknowledgeChat(session: DeviceSession, itemIds: [String]) async throws -> Int {
        guard !itemIds.isEmpty else { throw ControlApiError.invalidRequest }
        let value = try dictionary(await request(
            path: "/v1/chat/ack", body: ["itemIds": itemIds], accessToken: session.accessToken
        ))
        return try integer(value, "acknowledged")
    }

    public func uploadChatAttachment(
        session: DeviceSession,
        attachmentId: UUID,
        channelId: UUID,
        membershipEpoch: Int,
        ciphertext: Data,
        ciphertextSha256: Data,
        onProgress: (@Sendable (ChatTransferProgress) async -> Void)? = nil
    ) async throws -> ChatAttachmentUpload {
        guard membershipEpoch > 0, !ciphertext.isEmpty,
              ciphertext.count <= EncryptedChatCodec.maximumAttachmentBytes + 64,
              ciphertextSha256.count == 32 else { throw ControlApiError.invalidRequest }
        let attachmentPath = "/v1/chat/attachments/\(attachmentId.uuidString.lowercased())/uploads"
        let state = try dictionary(await request(path: attachmentPath, body: [
            "channelId": channelId.uuidString.lowercased(),
            "membershipEpoch": membershipEpoch,
            "ciphertextBytes": ciphertext.count,
            "ciphertextSha256": ciphertextSha256.hex,
        ], accessToken: session.accessToken))
        if try string(state, "state") == "complete" {
            await onProgress?(ChatTransferProgress(completedBytes: ciphertext.count, totalBytes: ciphertext.count))
            return try chatAttachmentUpload(state)
        }
        let uploadId = try string(state, "uploadId")
        let partSize = try integer(state, "partSize")
        guard UUID(uuidString: uploadId) != nil, (1...1_048_576).contains(partSize),
              let uploadedValues = state["uploadedParts"] as? [[String: Any]] else {
            throw ControlApiError.invalidResponse
        }
        var uploaded: [Int: (bytes: Int, digest: String)] = [:]
        for part in uploadedValues {
            uploaded[try integer(part, "partNumber")] = (
                try integer(part, "ciphertextBytes"), try string(part, "ciphertextSha256")
            )
        }
        let partCount = (ciphertext.count + partSize - 1) / partSize
        var completed = 0
        for partNumber in 1...partCount {
            let start = (partNumber - 1) * partSize
            let end = min(start + partSize, ciphertext.count)
            let part = ciphertext.subdata(in: start..<end)
            let digest = Data(SHA256.hash(data: part)).hex
            if let serverPart = uploaded[partNumber],
               (serverPart.bytes != part.count || serverPart.digest != digest) {
                throw ControlApiError.server(status: 409, code: "UPLOAD_PART_REUSED")
            }
            if uploaded[partNumber] == nil {
                do { try Task.checkCancellation() } catch {
                    try? await cancelChatAttachmentUpload(
                        session: session, attachmentPath: attachmentPath, uploadId: uploadId
                    )
                    throw error
                }
                try await uploadChatAttachmentPart(
                    session: session, attachmentPath: attachmentPath, uploadId: uploadId,
                    partNumber: partNumber, bytes: part, sha256: digest
                )
            }
            completed += part.count
            await onProgress?(ChatTransferProgress(completedBytes: completed, totalBytes: ciphertext.count))
        }
        do { try Task.checkCancellation() } catch {
            try? await cancelChatAttachmentUpload(
                session: session, attachmentPath: attachmentPath, uploadId: uploadId
            )
            throw error
        }
        let complete = try dictionary(await request(
            path: "\(attachmentPath)/\(uploadId)/complete", body: [:], accessToken: session.accessToken
        ))
        return try chatAttachmentUpload(complete)
    }

    private func uploadChatAttachmentPart(
        session: DeviceSession,
        attachmentPath: String,
        uploadId: String,
        partNumber: Int,
        bytes: Data,
        sha256: String
    ) async throws {
        _ = try await ensureCompatible()
        guard let url = URL(
            string: "\(attachmentPath)/\(uploadId)/parts/\(partNumber)", relativeTo: baseUrl
        )?.absoluteURL else { throw ControlApiError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 90)
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        request.setValue(sha256, forHTTPHeaderField: "X-Ciphertext-SHA256")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await urlSession.data(for: request)
        _ = try responseValue(data, response)
    }

    private func cancelChatAttachmentUpload(
        session: DeviceSession,
        attachmentPath: String,
        uploadId: String
    ) async throws {
        _ = try await request(
            path: "\(attachmentPath)/\(uploadId)", method: "DELETE", accessToken: session.accessToken
        )
    }

    private func chatAttachmentUpload(_ value: [String: Any]) throws -> ChatAttachmentUpload {
        guard let expiresAt = parseIso8601Date(try string(value, "expiresAt")) else {
            throw ControlApiError.invalidResponse
        }
        return try ChatAttachmentUpload(
            attachmentId: UUID(uuidString: string(value, "attachmentId")).unwrap(or: ControlApiError.invalidResponse),
            ciphertextBytes: integer(value, "ciphertextBytes"),
            ciphertextSha256: Data(hex: string(value, "ciphertextSha256")),
            expiresAt: expiresAt
        )
    }

    public func downloadChatAttachment(session: DeviceSession, attachmentId: UUID) async throws -> Data {
        var value = Data()
        var total: Int?
        var digest: Data?
        repeat {
            let chunk = try await downloadChatAttachmentChunk(
                session: session, attachmentId: attachmentId, offset: value.count
            )
            if let total, total != chunk.totalBytes { throw ControlApiError.invalidResponse }
            if let digest, digest != chunk.ciphertextSha256 { throw ControlApiError.invalidResponse }
            total = chunk.totalBytes
            digest = chunk.ciphertextSha256
            value.append(chunk.bytes)
        } while value.count < (total ?? 0)
        return value
    }

    public func downloadChatAttachmentChunk(
        session: DeviceSession,
        attachmentId: UUID,
        offset: Int,
        maximumBytes: Int = 1_048_576
    ) async throws -> ChatAttachmentDownloadChunk {
        guard offset >= 0, (1...1_048_576).contains(maximumBytes) else { throw ControlApiError.invalidRequest }
        _ = try await ensureCompatible()
        guard let url = URL(
            string: "/v1/chat/attachments/\(attachmentId.uuidString.lowercased())",
            relativeTo: baseUrl
        )?.absoluteURL else { throw ControlApiError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 90)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("bytes=\(offset)-\(offset + maximumBytes - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ControlApiError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            throw ControlApiError.server(status: http.statusCode, code: code ?? "REQUEST_FAILED")
        }
        guard let digestHex = http.value(forHTTPHeaderField: "X-Ciphertext-SHA256"),
              let digest = try? Data(hex: digestHex), digest.count == 32 else {
            throw ControlApiError.invalidResponse
        }
        let responseOffset: Int
        let totalBytes: Int
        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = parseContentRange(contentRange) {
            responseOffset = parsed.offset
            totalBytes = parsed.total
        } else if http.statusCode == 200, offset == 0 {
            responseOffset = 0
            totalBytes = data.count
        } else {
            throw ControlApiError.invalidResponse
        }
        guard responseOffset == offset, totalBytes > 0, offset + data.count <= totalBytes else {
            throw ControlApiError.invalidResponse
        }
        return ChatAttachmentDownloadChunk(
            bytes: data, offset: responseOffset, totalBytes: totalBytes, ciphertextSha256: digest
        )
    }

    public func uploadHistory(
        session: DeviceSession,
        announcement: MediaEpochAnnouncement,
        startedAt: Date,
        durationMs: Int,
        ciphertext: Data
    ) async throws -> HistoryMetadata {
        guard (1...30_000).contains(durationMs), !ciphertext.isEmpty else {
            throw ControlApiError.invalidRequest
        }
        return try historyMetadata(dictionary(await request(
            path: "/v1/history/objects",
            body: [
                "talkId": announcement.talkId.uuidString.lowercased(),
                "channelId": announcement.channelId.uuidString.lowercased(),
                "membershipEpoch": Int(announcement.membershipEpoch),
                "mediaKid": String(announcement.kid),
                "startedAt": iso8601String(startedAt),
                "durationMs": durationMs,
                "ciphertext": ciphertext.base64Url,
            ],
            accessToken: session.accessToken
        )))
    }

    public func history(session: DeviceSession, channelId: UUID, limit: Int = 100) async throws -> [HistoryMetadata] {
        guard (1...100).contains(limit) else { throw ControlApiError.invalidRequest }
        return try array(await request(
            path: "/v1/history/objects?channelId=\(channelId.uuidString.lowercased())&limit=\(limit)",
            method: "GET",
            accessToken: session.accessToken
        )).map { try historyMetadata(dictionary($0)) }
    }

    public func downloadHistory(session: DeviceSession, objectId: UUID) async throws -> DownloadedHistory {
        let value = try dictionary(await request(
            path: "/v1/history/objects/\(objectId.uuidString.lowercased())",
            method: "GET",
            accessToken: session.accessToken
        ))
        return try DownloadedHistory(
            metadata: historyMetadata(dictionary(value["metadata"] as Any)),
            ciphertext: Data(base64Url: string(value, "ciphertext"))
        )
    }

    public func registerPush(session: DeviceSession, provider: String, token: Data) async throws {
        guard ["apns", "apns-ptt"].contains(provider), (16...4_096).contains(token.count) else {
            throw ControlApiError.invalidRequest
        }
        _ = try await request(
            path: "/v1/push/registrations",
            body: ["provider": provider, "token": token.base64Url],
            accessToken: session.accessToken
        )
    }

    public func removePushRegistration(session: DeviceSession, provider: String) async throws {
        guard ["apns", "apns-ptt"].contains(provider) else { throw ControlApiError.invalidRequest }
        _ = try await request(
            path: "/v1/push/registrations",
            method: "DELETE",
            body: ["provider": provider],
            accessToken: session.accessToken
        )
    }

    public func setPresence(session: DeviceSession, mode: String) async throws {
        guard ["available", "busy", "solo", "standby"].contains(mode) else {
            throw ControlApiError.invalidRequest
        }
        _ = try await request(
            path: "/v1/presence",
            body: ["mode": mode],
            accessToken: session.accessToken
        )
    }

    private func request(
        path: String,
        method: String = "POST",
        body: [String: Any]? = nil,
        accessToken: String? = nil
    ) async throws -> Any {
        _ = try await ensureCompatible()
        guard let url = URL(string: path, relativeTo: baseUrl)?.absoluteURL else {
            throw ControlApiError.invalidRequest
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else { throw ControlApiError.invalidRequest }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ControlApiError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            throw ControlApiError.server(status: http.statusCode, code: code ?? "REQUEST_FAILED")
        }
        if data.isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func ensureCompatible() async throws -> ServerProtocolCompatibility {
        let key = baseUrl.absoluteString
        if let cached = await ServerCompatibilityCache.shared.value(for: key) { return cached }
        guard let url = URL(string: "/healthz", relativeTo: baseUrl)?.absoluteURL else {
            throw ControlApiError.invalidServerUrl
        }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw ControlApiError.server(status: 503, code: "SERVER_COMPATIBILITY_UNAVAILABLE") }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlApiError.server(status: 503, code: "SERVER_COMPATIBILITY_UNAVAILABLE")
        }
        let compatible = try ProductProtocolContract.validate(value)
        await ServerCompatibilityCache.shared.store(compatible, for: key)
        return compatible
    }

    private func responseValue(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw ControlApiError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            throw ControlApiError.server(status: http.statusCode, code: code ?? "REQUEST_FAILED")
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlApiError.invalidResponse
        }
        return value
    }

    private func session(_ value: [String: Any]) throws -> DeviceSession {
        try DeviceSession(
            serverUrl: baseUrl.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            aci: string(value, "aci"),
            deviceId: integer(value, "deviceId"),
            mailboxId: string(value, "mailboxId"),
            accessToken: string(value, "accessToken")
        )
    }

    private func historyMetadata(_ value: [String: Any]) throws -> HistoryMetadata {
        guard let objectId = UUID(uuidString: try string(value, "objectId")),
              let talkId = UUID(uuidString: try string(value, "talkId")),
              let channelId = UUID(uuidString: try string(value, "channelId")),
              let startedAt = parseIso8601Date(try string(value, "startedAt")),
              let expiresAt = parseIso8601Date(try string(value, "expiresAt"))
        else { throw ControlApiError.invalidResponse }
        return HistoryMetadata(
            objectId: objectId,
            talkId: talkId,
            channelId: channelId,
            membershipEpoch: try integer(value, "membershipEpoch"),
            mediaKid: try UInt64(string(value, "mediaKid")).unwrap(or: ControlApiError.invalidResponse),
            startedAt: startedAt,
            durationMs: try integer(value, "durationMs"),
            expiresAt: expiresAt,
            ciphertextBytes: try integer(value, "ciphertextBytes")
        )
    }
}

func parseIso8601Date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func parseContentRange(_ value: String) -> (offset: Int, end: Int, total: Int)? {
    let expression = try? NSRegularExpression(pattern: #"^bytes (\d+)-(\d+)/(\d+)$"#)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression?.firstMatch(in: value, range: range), match.numberOfRanges == 4,
          let startRange = Range(match.range(at: 1), in: value),
          let endRange = Range(match.range(at: 2), in: value),
          let totalRange = Range(match.range(at: 3), in: value),
          let start = Int(value[startRange]), let end = Int(value[endRange]), let total = Int(value[totalRange]),
          start >= 0, end >= start, total > end else { return nil }
    return (start, end, total)
}

public enum ControlApiError: Error, Equatable {
    case invalidServerUrl
    case insecureServerUrl
    case invalidRequest
    case invalidResponse
    case invalidBase64Url
    case server(status: Int, code: String)
}

extension ControlApiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .server(_, "SERVER_UPGRADE_REQUIRED"), .server(_, "SERVER_CAPABILITY_REQUIRED"):
            "This team server must be upgraded before this version of PTT Talk can connect securely."
        case .server(_, "CLIENT_UPGRADE_REQUIRED"):
            "Update PTT Talk before reconnecting to this team server."
        case .server(_, "SERVER_COMPATIBILITY_UNAVAILABLE"):
            "Could not verify that this team server supports the required secure protocol."
        case .invalidServerUrl: "Enter a valid server URL."
        case .insecureServerUrl: "The server must use HTTPS."
        case .invalidRequest: "The request is invalid."
        case .invalidResponse: "The team server returned an invalid response."
        case .invalidBase64Url: "The server returned invalid encoded data."
        case let .server(_, code): "The server rejected the request (\(code))."
        }
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    var base64Url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(base64Url value: String) throws {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        guard let decoded = Data(base64Encoded: normalized) else { throw ControlApiError.invalidBase64Url }
        self = decoded
    }

    static func random(count: Int) -> Data {
        precondition(count > 0)
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(result == errSecSuccess)
        return Data(bytes)
    }

    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            throw ControlApiError.invalidResponse
        }
        var value = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw ControlApiError.invalidResponse }
            value.append(byte)
            index = next
        }
        self = value
    }
}

private func dictionary(_ value: Any) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw ControlApiError.invalidResponse }
    return value
}

private func array(_ value: Any) throws -> [Any] {
    guard let value = value as? [Any] else { throw ControlApiError.invalidResponse }
    return value
}

private func string(_ value: [String: Any], _ key: String) throws -> String {
    guard let result = value[key] as? String, !result.isEmpty else { throw ControlApiError.invalidResponse }
    return result
}

private func number(_ value: [String: Any], _ key: String) -> NSNumber? { value[key] as? NSNumber }

private func integer(_ value: [String: Any], _ key: String) throws -> Int {
    guard let result = number(value, key) else { throw ControlApiError.invalidResponse }
    return result.intValue
}

private func unsignedInteger(_ value: [String: Any], _ key: String) throws -> UInt64 {
    guard let result = number(value, key), result.int64Value >= 0 else { throw ControlApiError.invalidResponse }
    return result.uint64Value
}

private func boolean(_ value: [String: Any], _ key: String) throws -> Bool {
    guard let result = number(value, key) else { throw ControlApiError.invalidResponse }
    return result.boolValue
}

private func pathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
