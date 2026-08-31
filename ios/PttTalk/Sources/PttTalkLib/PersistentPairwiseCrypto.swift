import CryptoKit
import Foundation
import LibSignalClient

public struct MediaEpochAnnouncement: Equatable, Sendable {
    public let channelId: UUID
    public let talkId: UUID
    public let membershipEpoch: Int32
    public let senderDemux: UInt32
    public let kid: UInt64
    public let baseKey: Data
    public let totMs: Int32
    public let isSos: Bool

    public init(
        channelId: UUID,
        talkId: UUID,
        membershipEpoch: Int32,
        senderDemux: UInt32,
        kid: UInt64,
        baseKey: Data,
        totMs: Int32,
        isSos: Bool = false
    ) {
        self.channelId = channelId
        self.talkId = talkId
        self.membershipEpoch = membershipEpoch
        self.senderDemux = senderDemux
        self.kid = kid
        self.baseKey = baseKey
        self.totMs = totMs
        self.isSos = isSos
    }
}

public struct OpenedPairwiseEnvelope: Equatable, Sendable {
    public let senderAci: String
    public let senderDeviceId: Int
    public let announcement: MediaEpochAnnouncement
}

public struct OpenedPairwiseData: Equatable, Sendable {
    public let senderAci: String
    public let senderDeviceId: Int
    public let plaintext: Data
}

public actor PersistentPairwiseCrypto {
    private enum PairwiseDomain {
        case voice
        case chat

        func addressName(_ aci: String) -> String {
            switch self {
            case .voice: aci.lowercased()
            case .chat: "ptt-chat-v1:\(aci.lowercased())"
            }
        }
    }
    private static let prekeyPublishedAt = "prekeys-published-at"
    private static let baseDescriptorKey = "prekey-base-v1"
    private static let replenishInterval: TimeInterval = 24 * 60 * 60
    private static let outerMagic = Data("PTTE".utf8)
    private static let groupMagic = Data("PTTG".utf8)
    private static let senderKeyMagic = Data("PTTK".utf8)
    private static let announcementMagic = Data("PTTM".utf8)

    private let session: DeviceSession
    private let api: ControlApi
    private let store: KeychainSignalProtocolStore
    private let prekeyPublishedAtStateKey: String
    private let context = NullContext()

    public init(
        session: DeviceSession,
        store: KeychainSignalProtocolStore,
        allowInsecureHttp: Bool = false
    ) throws {
        self.session = session
        self.store = store
        self.prekeyPublishedAtStateKey = Self.prekeyPublishedAtStateKey(
            serverUrl: session.serverUrl,
            aci: session.aci,
            deviceId: session.deviceId
        )
        self.api = try ControlApi(serverUrl: session.serverUrl, allowInsecureHttp: allowInsecureHttp)
    }

    public func ensurePreKeysPublished(
        now: Date = Date(),
        initialBatchSize: Int = 100,
        replenishmentBatchSize: Int = 20
    ) async throws {
        guard (1...100).contains(initialBatchSize), (1...100).contains(replenishmentBatchSize) else {
            throw PersistentCryptoError.invalidPrekeyBatch
        }
        let last = try store.applicationState(prekeyPublishedAtStateKey).flatMap {
            ISO8601DateFormatter().date(from: String(decoding: $0, as: UTF8.self))
        }
        if let last, now.timeIntervalSince(last) < Self.replenishInterval { return }

        let descriptor = try baseDescriptor(now: now)
        let count = last == nil ? initialBatchSize : replenishmentBatchSize
        var keys: [OneTimePreKeyUpload] = []
        keys.reserveCapacity(count * 2)
        for _ in 0..<count {
            let ecId = try store.nextRecordId(kind: "ec-prekey")
            let ec = PrivateKey.generate()
            try store.storePreKey(
                PreKeyRecord(id: ecId, privateKey: ec),
                id: ecId,
                context: context
            )
            keys.append(OneTimePreKeyUpload(kind: "x25519", keyId: ecId, publicKey: ec.publicKey.serialize()))

            let kyberId = try store.nextRecordId(kind: "kyber-prekey")
            let kyber = KEMKeyPair.generate()
            let signature = try store.identityKeyPair(context: context).privateKey
                .generateSignature(message: kyber.publicKey.serialize())
            try store.storeKyberPreKey(
                KyberPreKeyRecord(
                    id: kyberId,
                    timestamp: UInt64(now.timeIntervalSince1970 * 1_000),
                    keyPair: kyber,
                    signature: signature
                ),
                id: kyberId,
                context: context
            )
            keys.append(OneTimePreKeyUpload(
                kind: "kyber",
                keyId: kyberId,
                publicKey: try Self.encodeKyberOneTime(publicKey: kyber.publicKey.serialize(), signature: signature)
            ))
        }
        try await api.uploadPreKeys(session: session, opaqueBundle: descriptor, oneTimePreKeys: keys)
        try store.putApplicationState(
            prekeyPublishedAtStateKey,
            value: Data(ISO8601DateFormatter().string(from: now).utf8)
        )
    }

    nonisolated static func prekeyPublishedAtStateKey(
        serverUrl: String,
        aci: String,
        deviceId: Int
    ) -> String {
        precondition((1...2).contains(deviceId))
        let scope = "\(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))\n\(aci.lowercased())\n\(deviceId)"
        let opaqueScope = SHA256.hash(data: Data(scope.utf8)).prefix(20)
            .map { String(format: "%02x", $0) }.joined()
        return "\(prekeyPublishedAt)-\(opaqueScope)"
    }

    public func encryptFor(device: ChannelDevice, plaintext: Data) async throws -> Data {
        try await encryptFor(device: device, plaintext: plaintext, domain: .voice)
    }

    /// Chat and live-media key announcements use independent Double Ratchets.
    /// Their server queues are polled independently, so sharing one ratchet
    /// would allow a regular chat SignalMessage to arrive before the voice
    /// queue's initial PreKeySignalMessage and make valid traffic undecryptable.
    public func encryptDataFor(device: ChannelDevice, plaintext: Data) async throws -> Data {
        try await encryptFor(device: device, plaintext: plaintext, domain: .chat)
    }

    private func encryptFor(
        device: ChannelDevice,
        plaintext: Data,
        domain: PairwiseDomain
    ) async throws -> Data {
        guard device.aci != session.aci || device.deviceId != session.deviceId else {
            throw PersistentCryptoError.localRecipient
        }
        let remote = try ProtocolAddress(
            name: domain.addressName(device.aci), deviceId: UInt32(device.deviceId)
        )
        let local = try ProtocolAddress(
            name: domain.addressName(session.aci), deviceId: UInt32(session.deviceId)
        )
        if try store.loadSession(for: remote, context: context) == nil {
            guard let fetched = try await api.fetchPreKeys(
                session: session,
                devices: [(device.aci, device.deviceId)]
            ).first else { throw PersistentCryptoError.prekeysUnavailable }
            let descriptor = try PreKeyDescriptor.decode(fetched.opaqueBundle)
            guard descriptor.identityKey == device.identityKey else {
                throw PersistentCryptoError.membershipIdentityMismatch
            }
            try processPreKeyBundle(
                fetched.libsignalBundle(descriptor: descriptor),
                for: remote,
                ourAddress: local,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        }
        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: remote,
            localAddress: local,
            sessionStore: store,
            identityStore: store,
            context: context
        ).serialize()
        return try Self.encodeOuterEnvelope(
            senderAci: session.aci,
            senderDeviceId: session.deviceId,
            ciphertext: ciphertext
        )
    }

    public func decryptEnvelope(
        _ envelope: Data,
        allowedDevices: [ChannelDevice]? = nil,
        expectedDistributionId: UUID? = nil
    ) throws -> OpenedPairwiseEnvelope {
        if envelope.prefix(4) == Self.groupMagic {
            let outer = try Self.decodeGroupEnvelope(envelope)
            if let expectedDistributionId, outer.distributionId != expectedDistributionId {
                throw PersistentCryptoError.invalidEnvelope
            }
            let keyEnvelope = try decryptPairwiseRaw(outer.keyEnvelope, allowedDevices: allowedDevices)
            guard keyEnvelope.senderAci == outer.senderAci,
                  keyEnvelope.senderDeviceId == outer.senderDeviceId else {
                throw PersistentCryptoError.unauthorizedSender
            }
            let distribution = try Self.decodeSenderKeyDistribution(keyEnvelope.plaintext)
            guard distribution.distributionId == outer.distributionId else {
                throw PersistentCryptoError.invalidEnvelope
            }
            let sender = try ProtocolAddress(name: outer.senderAci, deviceId: UInt32(outer.senderDeviceId))
            try processSenderKeyDistributionMessage(
                SenderKeyDistributionMessage(bytes: distribution.message),
                from: sender,
                store: store,
                context: context
            )
            let plaintext = try groupDecrypt(
                outer.ciphertext,
                from: sender,
                store: store,
                context: context
            )
            return OpenedPairwiseEnvelope(
                senderAci: outer.senderAci,
                senderDeviceId: outer.senderDeviceId,
                announcement: try Self.decodeAnnouncement(plaintext)
            )
        }
        let opened = try decryptPairwiseRaw(
            envelope, allowedDevices: allowedDevices, domain: .voice
        )
        return OpenedPairwiseEnvelope(
            senderAci: opened.senderAci,
            senderDeviceId: opened.senderDeviceId,
            announcement: try Self.decodeAnnouncement(opened.plaintext)
        )
    }

    /// Opens a non-voice pairwise payload while applying the same active-device
    /// identity check used for media epoch announcements.
    public func decryptDataEnvelope(
        _ envelope: Data,
        allowedDevices: [ChannelDevice]? = nil
    ) throws -> OpenedPairwiseData {
        guard envelope.prefix(4) == Self.outerMagic else { throw PersistentCryptoError.invalidEnvelope }
        let opened = try decryptPairwiseRaw(
            envelope, allowedDevices: allowedDevices, domain: .chat
        )
        return OpenedPairwiseData(
            senderAci: opened.senderAci,
            senderDeviceId: opened.senderDeviceId,
            plaintext: opened.plaintext
        )
    }

    private func decryptPairwiseRaw(
        _ envelope: Data,
        allowedDevices: [ChannelDevice]? = nil,
        domain: PairwiseDomain = .voice
    ) throws -> (senderAci: String, senderDeviceId: Int, plaintext: Data) {
        let outer = try Self.decodeOuterEnvelope(envelope)
        let expected = allowedDevices?.first {
            $0.aci == outer.senderAci && $0.deviceId == outer.senderDeviceId
        }
        if allowedDevices != nil, expected == nil { throw PersistentCryptoError.unauthorizedSender }

        let local = try ProtocolAddress(
            name: domain.addressName(session.aci), deviceId: UInt32(session.deviceId)
        )
        let sender = try ProtocolAddress(
            name: domain.addressName(outer.senderAci), deviceId: UInt32(outer.senderDeviceId)
        )
        let plaintext: Data
        if let prekey = try? PreKeySignalMessage(bytes: outer.ciphertext) {
            plaintext = try signalDecryptPreKey(
                message: prekey,
                from: sender,
                localAddress: local,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: context
            )
        } else {
            plaintext = try signalDecrypt(
                message: SignalMessage(bytes: outer.ciphertext),
                from: sender,
                to: local,
                sessionStore: store,
                identityStore: store,
                context: context
            )
        }
        if let expected {
            guard let established = try store.identity(for: sender, context: context),
                  established.serialize() == expected.identityKey else {
                throw PersistentCryptoError.membershipIdentityMismatch
            }
        }
        return (outer.senderAci, outer.senderDeviceId, plaintext)
    }

    public func announceMediaEpoch(
        devices: [ChannelDevice],
        distributionId: UUID,
        announcement: MediaEpochAnnouncement
    ) async throws -> Int {
        let plaintext = try Self.encodeAnnouncement(announcement)
        let local = try ProtocolAddress(name: session.aci, deviceId: UInt32(session.deviceId))
        let distributionMessage = try SenderKeyDistributionMessage(
            from: local,
            distributionId: distributionId,
            store: store,
            context: context
        ).serialize()
        let groupCiphertext = try groupEncrypt(
            plaintext,
            from: local,
            distributionId: distributionId,
            store: store,
            context: context
        ).serialize()
        let distributionPlaintext = try Self.encodeSenderKeyDistribution(
            distributionId: distributionId,
            message: distributionMessage
        )
        var recipients: [MailboxRecipient] = []
        for device in devices where device.aci != session.aci || device.deviceId != session.deviceId {
            let authenticatedDistribution = try await encryptFor(
                device: device,
                plaintext: distributionPlaintext
            )
            recipients.append(MailboxRecipient(
                aci: device.aci,
                deviceId: device.deviceId,
                envelope: try Self.encodeGroupEnvelope(
                    senderAci: session.aci,
                    senderDeviceId: session.deviceId,
                    distributionId: distributionId,
                    keyEnvelope: authenticatedDistribution,
                    ciphertext: groupCiphertext
                )
            ))
        }
        guard !recipients.isEmpty else { return 0 }
        return try await api.enqueueMailbox(
            session: session,
            messageId: announcement.talkId.uuidString.lowercased(),
            recipients: recipients,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
    }

    private func baseDescriptor(now: Date) throws -> Data {
        if let existing = try store.applicationState(Self.baseDescriptorKey) { return existing }
        let identity = try store.identityKeyPair(context: context)
        let timestamp = UInt64(now.timeIntervalSince1970 * 1_000)
        let signedId = try store.nextRecordId(kind: "signed-prekey")
        let signedPrivate = PrivateKey.generate()
        let signedSignature = identity.privateKey.generateSignature(message: signedPrivate.publicKey.serialize())
        try store.storeSignedPreKey(
            SignedPreKeyRecord(
                id: signedId,
                timestamp: timestamp,
                privateKey: signedPrivate,
                signature: signedSignature
            ),
            id: signedId,
            context: context
        )

        let kyberId = try store.nextRecordId(kind: "last-resort-kyber")
        let kyber = KEMKeyPair.generate()
        let kyberSignature = identity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        try store.storeKyberPreKey(
            KyberPreKeyRecord(
                id: kyberId,
                timestamp: timestamp,
                keyPair: kyber,
                signature: kyberSignature
            ),
            id: kyberId,
            context: context
        )
        let descriptor = try PreKeyDescriptor(
            registrationId: try store.localRegistrationId(context: context),
            identityKey: identity.identityKey.serialize(),
            signedPreKeyId: signedId,
            signedPreKey: signedPrivate.publicKey.serialize(),
            signedPreKeySignature: signedSignature,
            lastResortKyberId: kyberId,
            lastResortKyber: kyber.publicKey.serialize(),
            lastResortKyberSignature: kyberSignature
        ).encode()
        try store.putApplicationState(Self.baseDescriptorKey, value: descriptor)
        return descriptor
    }

    static func encodeOuterEnvelope(senderAci: String, senderDeviceId: Int, ciphertext: Data) throws -> Data {
        guard let aci = UUID(uuidString: senderAci), (1...2).contains(senderDeviceId), !ciphertext.isEmpty else {
            throw PersistentCryptoError.invalidEnvelope
        }
        var output = outerMagic
        output.append(1)
        output.append(contentsOf: uuidBytes(aci))
        output.append(UInt8(senderDeviceId))
        output.append(ciphertext)
        return output
    }

    static func decodeOuterEnvelope(_ bytes: Data) throws -> (senderAci: String, senderDeviceId: Int, ciphertext: Data) {
        guard bytes.count > 22, bytes.prefix(4) == outerMagic, bytes[4] == 1 else {
            throw PersistentCryptoError.invalidEnvelope
        }
        let sender = try uuid(bytes.subdata(in: 5..<21)).uuidString.lowercased()
        let device = Int(bytes[21])
        guard (1...2).contains(device) else { throw PersistentCryptoError.invalidEnvelope }
        return (sender, device, bytes.subdata(in: 22..<bytes.count))
    }

    static func encodeGroupEnvelope(
        senderAci: String,
        senderDeviceId: Int,
        distributionId: UUID,
        keyEnvelope: Data,
        ciphertext: Data
    ) throws -> Data {
        guard let aci = UUID(uuidString: senderAci), (1...2).contains(senderDeviceId),
              !keyEnvelope.isEmpty, keyEnvelope.count <= 65_535, !ciphertext.isEmpty else {
            throw PersistentCryptoError.invalidEnvelope
        }
        var output = groupMagic
        output.append(1)
        output.append(contentsOf: uuidBytes(aci))
        output.append(UInt8(senderDeviceId))
        output.append(contentsOf: uuidBytes(distributionId))
        append(UInt32(keyEnvelope.count), to: &output)
        output.append(keyEnvelope)
        output.append(ciphertext)
        return output
    }

    static func decodeGroupEnvelope(
        _ bytes: Data
    ) throws -> (senderAci: String, senderDeviceId: Int, distributionId: UUID, keyEnvelope: Data, ciphertext: Data) {
        guard bytes.count > 42, bytes.prefix(4) == groupMagic, bytes[4] == 1 else {
            throw PersistentCryptoError.invalidEnvelope
        }
        let sender = try uuid(bytes.subdata(in: 5..<21)).uuidString.lowercased()
        let device = Int(bytes[21])
        let distributionId = try uuid(bytes.subdata(in: 22..<38))
        let keyEnvelopeCount = Int(read(bytes, offset: 38) as UInt32)
        let keyStart = 42
        let keyEnd = keyStart + keyEnvelopeCount
        guard (1...2).contains(device), keyEnvelopeCount > 0, keyEnd < bytes.count else {
            throw PersistentCryptoError.invalidEnvelope
        }
        return (
            sender,
            device,
            distributionId,
            bytes.subdata(in: keyStart..<keyEnd),
            bytes.subdata(in: keyEnd..<bytes.count)
        )
    }

    static func encodeSenderKeyDistribution(distributionId: UUID, message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= 65_535 else {
            throw PersistentCryptoError.invalidEnvelope
        }
        var output = senderKeyMagic
        output.append(1)
        output.append(contentsOf: uuidBytes(distributionId))
        append(UInt32(message.count), to: &output)
        output.append(message)
        return output
    }

    static func decodeSenderKeyDistribution(
        _ bytes: Data
    ) throws -> (distributionId: UUID, message: Data) {
        guard bytes.count > 25, bytes.prefix(4) == senderKeyMagic, bytes[4] == 1 else {
            throw PersistentCryptoError.invalidEnvelope
        }
        let distributionId = try uuid(bytes.subdata(in: 5..<21))
        let length = Int(read(bytes, offset: 21) as UInt32)
        guard length > 0, length == bytes.count - 25 else {
            throw PersistentCryptoError.invalidEnvelope
        }
        return (distributionId, bytes.subdata(in: 25..<bytes.count))
    }

    static func encodeAnnouncement(_ value: MediaEpochAnnouncement) throws -> Data {
        guard value.membershipEpoch > 0, value.senderDemux > 0, value.baseKey.count == 32,
              (1...60_000).contains(value.totMs) else {
            throw PersistentCryptoError.invalidAnnouncement
        }
        var output = announcementMagic
        output.append(2)
        output.append(value.isSos ? 1 : 0)
        output.append(contentsOf: uuidBytes(value.channelId))
        output.append(contentsOf: uuidBytes(value.talkId))
        append(value.membershipEpoch, to: &output)
        append(value.senderDemux, to: &output)
        append(value.kid, to: &output)
        append(value.totMs, to: &output)
        output.append(value.baseKey)
        return output
    }

    static func decodeAnnouncement(_ bytes: Data) throws -> MediaEpochAnnouncement {
        guard (bytes.count == 89 || bytes.count == 90), bytes.prefix(4) == announcementMagic,
              bytes[4] == 1 || bytes[4] == 2 else {
            throw PersistentCryptoError.invalidAnnouncement
        }
        let version = bytes[4]
        let base = version == 2 ? 1 : 0
        let flags = version == 2 ? bytes[5] : 0
        guard flags & 0xfe == 0 else { throw PersistentCryptoError.invalidAnnouncement }
        let epoch: Int32 = read(bytes, offset: 37 + base)
        let demux: UInt32 = read(bytes, offset: 41 + base)
        let kid: UInt64 = read(bytes, offset: 45 + base)
        let tot: Int32 = read(bytes, offset: 53 + base)
        guard epoch > 0, demux > 0, (1...60_000).contains(tot) else {
            throw PersistentCryptoError.invalidAnnouncement
        }
        return MediaEpochAnnouncement(
            channelId: try uuid(bytes.subdata(in: (5 + base)..<(21 + base))),
            talkId: try uuid(bytes.subdata(in: (21 + base)..<(37 + base))),
            membershipEpoch: epoch,
            senderDemux: demux,
            kid: kid,
            baseKey: bytes.subdata(in: (57 + base)..<(89 + base)),
            totMs: tot,
            isSos: flags & 1 != 0
        )
    }

    private static func encodeKyberOneTime(publicKey: Data, signature: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "publicKey": publicKey.base64Url,
            "signature": signature.base64Url,
        ], options: [.sortedKeys])
    }
}

public enum PersistentCryptoError: Error, Equatable {
    case invalidPrekeyBatch
    case localRecipient
    case prekeysUnavailable
    case membershipIdentityMismatch
    case unauthorizedSender
    case invalidEnvelope
    case invalidAnnouncement
    case invalidDescriptor
}

private struct PreKeyDescriptor {
    let registrationId: UInt32
    let identityKey: Data
    let signedPreKeyId: UInt32
    let signedPreKey: Data
    let signedPreKeySignature: Data
    let lastResortKyberId: UInt32
    let lastResortKyber: Data
    let lastResortKyberSignature: Data

    func encode() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "registrationId": registrationId,
            "identityKey": identityKey.base64Url,
            "signedPreKeyId": signedPreKeyId,
            "signedPreKey": signedPreKey.base64Url,
            "signedPreKeySignature": signedPreKeySignature.base64Url,
            "lastResortKyberId": lastResortKyberId,
            "lastResortKyber": lastResortKyber.base64Url,
            "lastResortKyberSignature": lastResortKyberSignature.base64Url,
        ], options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> PreKeyDescriptor {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["version"] as? NSNumber)?.intValue == 1 else {
            throw PersistentCryptoError.invalidDescriptor
        }
        func id(_ key: String) throws -> UInt32 {
            guard let n = value[key] as? NSNumber, n.int64Value > 0, n.uint64Value <= UInt64(UInt32.max) else {
                throw PersistentCryptoError.invalidDescriptor
            }
            return n.uint32Value
        }
        func bytes(_ key: String) throws -> Data {
            guard let string = value[key] as? String else { throw PersistentCryptoError.invalidDescriptor }
            return try Data(base64Url: string)
        }
        return try PreKeyDescriptor(
            registrationId: id("registrationId"),
            identityKey: bytes("identityKey"),
            signedPreKeyId: id("signedPreKeyId"),
            signedPreKey: bytes("signedPreKey"),
            signedPreKeySignature: bytes("signedPreKeySignature"),
            lastResortKyberId: id("lastResortKyberId"),
            lastResortKyber: bytes("lastResortKyber"),
            lastResortKyberSignature: bytes("lastResortKyberSignature")
        )
    }
}

private extension FetchedPreKey {
    func libsignalBundle(descriptor: PreKeyDescriptor) throws -> PreKeyBundle {
        let ec = oneTimePreKeys.first { $0.kind == "x25519" }
        let kyber = oneTimePreKeys.first { $0.kind == "kyber" }
        let oneTimeKyber = try kyber.map { try decodeKyberOneTime($0.publicKey) }
        if let ec {
            return try PreKeyBundle(
                registrationId: descriptor.registrationId,
                deviceId: UInt32(deviceId),
                prekeyId: ec.keyId,
                prekey: PublicKey(ec.publicKey),
                signedPrekeyId: descriptor.signedPreKeyId,
                signedPrekey: PublicKey(descriptor.signedPreKey),
                signedPrekeySignature: descriptor.signedPreKeySignature,
                identity: IdentityKey(bytes: descriptor.identityKey),
                kyberPrekeyId: kyber?.keyId ?? descriptor.lastResortKyberId,
                kyberPrekey: KEMPublicKey(oneTimeKyber?.0 ?? descriptor.lastResortKyber),
                kyberPrekeySignature: oneTimeKyber?.1 ?? descriptor.lastResortKyberSignature
            )
        }
        return try PreKeyBundle(
            registrationId: descriptor.registrationId,
            deviceId: UInt32(deviceId),
            signedPrekeyId: descriptor.signedPreKeyId,
            signedPrekey: PublicKey(descriptor.signedPreKey),
            signedPrekeySignature: descriptor.signedPreKeySignature,
            identity: IdentityKey(bytes: descriptor.identityKey),
            kyberPrekeyId: kyber?.keyId ?? descriptor.lastResortKyberId,
            kyberPrekey: KEMPublicKey(oneTimeKyber?.0 ?? descriptor.lastResortKyber),
            kyberPrekeySignature: oneTimeKyber?.1 ?? descriptor.lastResortKyberSignature
        )
    }
}

private func decodeKyberOneTime(_ data: Data) throws -> (Data, Data) {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          (value["version"] as? NSNumber)?.intValue == 1,
          let key = value["publicKey"] as? String,
          let signature = value["signature"] as? String else {
        throw PersistentCryptoError.invalidDescriptor
    }
    return try (Data(base64Url: key), Data(base64Url: signature))
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    data.append(Data(bytes: &bigEndian, count: MemoryLayout<T>.size))
}

private func read<T: FixedWidthInteger>(_ data: Data, offset: Int) -> T {
    data[offset..<(offset + MemoryLayout<T>.size)].reduce(T(0)) { ($0 << 8) | T($1) }
}

private func uuidBytes(_ value: UUID) -> [UInt8] {
    let bytes = value.uuid
    return [
        bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
        bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
    ]
}

private func uuid(_ data: Data) throws -> UUID {
    guard data.count == 16 else { throw PersistentCryptoError.invalidEnvelope }
    let b = [UInt8](data)
    return UUID(uuid: (
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
    ))
}
