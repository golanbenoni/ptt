import CryptoKit
import Foundation
import LibSignalClient
import PttWire
import Security

private let processKeychainLock = NSRecursiveLock()

final class KeychainVault {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func get(_ account: String) throws -> Data? {
        try processKeychainLock.withLock {
            var query = baseQuery(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw KeychainStoreError.keychain(status)
            }
            return data
        }
    }

    func put(_ account: String, _ value: Data) throws {
        try processKeychainLock.withLock {
            let query = baseQuery(account)
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw KeychainStoreError.keychain(status) }
            var addition = query
            addition[kSecValueData as String] = value
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(
                    query as CFDictionary,
                    [kSecValueData as String: value] as CFDictionary
                )
                guard retryStatus == errSecSuccess else { throw KeychainStoreError.keychain(retryStatus) }
                return
            }
            throw KeychainStoreError.keychain(addStatus)
        }
    }

    func delete(_ account: String) throws {
        try processKeychainLock.withLock {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.keychain(status)
            }
        }
    }

    func deleteAll() throws {
        try processKeychainLock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.keychain(status)
            }
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class SecureDeviceStore: @unchecked Sendable {
    private struct StoredValue: Codable {
        let kind: String
        let session: DeviceSession?
        let recovery: PendingRecovery?
        let deviceLink: PendingDeviceLink?
        let serverUrl: String?
    }

    private let vault: KeychainVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(namespace: String = "app.ptt.talk.device-session.v1") {
        vault = KeychainVault(service: namespace)
    }

    public func save(session: DeviceSession) throws {
        try save(StoredValue(kind: "session", session: session, recovery: nil, deviceLink: nil, serverUrl: nil))
    }

    public func loadSession() throws -> DeviceSession? {
        let stored = try load()
        return stored?.kind == "session" ? stored?.session : nil
    }

    public func save(recovery: PendingRecovery) throws {
        try save(StoredValue(kind: "recovery", session: nil, recovery: recovery, deviceLink: nil, serverUrl: nil))
    }

    public func loadRecovery() throws -> PendingRecovery? {
        let stored = try load()
        return stored?.kind == "recovery" ? stored?.recovery : nil
    }

    public func save(deviceLink: PendingDeviceLink) throws {
        try save(StoredValue(kind: "device-link", session: nil, recovery: nil, deviceLink: deviceLink, serverUrl: nil))
    }

    public func loadDeviceLink() throws -> PendingDeviceLink? {
        let stored = try load()
        return stored?.kind == "device-link" ? stored?.deviceLink : nil
    }

    public func saveServerUrl(_ value: String) throws {
        try save(StoredValue(
            kind: "configuration",
            session: nil,
            recovery: nil,
            deviceLink: nil,
            serverUrl: value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ))
    }

    public func loadServerUrl() throws -> String? { try load()?.serverUrl }

    public func clear() throws {
        try vault.delete("current")
        try vault.delete("enrollment-resume")
    }

    public func enrollmentResumeSecret() throws -> Data {
        if let existing = try vault.get("enrollment-resume"), existing.count == 32 { return existing }
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainStoreError.keychain(status) }
        try vault.put("enrollment-resume", secret)
        return secret
    }

    public func clearEnrollmentResumeSecret() throws { try vault.delete("enrollment-resume") }

    private func save(_ value: StoredValue) throws { try vault.put("current", encoder.encode(value)) }

    private func load() throws -> StoredValue? {
        guard let data = try vault.get("current") else { return nil }
        do { return try decoder.decode(StoredValue.self, from: data) }
        catch {
            try? clear()
            throw KeychainStoreError.corruptRecord
        }
    }
}

/// Durable libsignal records backed by the device-only Keychain. Every mutating
/// protocol callback writes before returning, including ratchet session updates.
public final class KeychainSignalProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore, SenderKeyStore, SFrameCounterStore, @unchecked Sendable
{
    public static func resetLocalDeviceState(namespace: String = "app.ptt.talk.signal-store.v1") throws {
        try KeychainVault(service: namespace).deleteAll()
    }

    private let vault: KeychainVault
    private let identity: IdentityKeyPair
    private let registrationId: UInt32

    public init(namespace: String = "app.ptt.talk.signal-store.v1") throws {
        let localVault = KeychainVault(service: namespace)
        let initialized: (IdentityKeyPair, UInt32) = try processKeychainLock.withLock {
            let identity: IdentityKeyPair
            if let bytes = try localVault.get("local/identity") {
                identity = try IdentityKeyPair(bytes: bytes)
            } else {
                identity = IdentityKeyPair.generate()
                try localVault.put("local/identity", identity.serialize())
            }
            let registration: UInt32
            if let bytes = try localVault.get("local/registration") {
                registration = try decodeUInt32(bytes)
            } else {
                registration = UInt32.random(in: 1...0x3fff)
                try localVault.put("local/registration", encode(registration))
            }
            return (identity, registration)
        }
        vault = localVault
        identity = initialized.0
        registrationId = initialized.1
    }

    public var identityPublicKey: Data { identity.identityKey.serialize() }

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }
    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    public func saveIdentity(
        _ value: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try processKeychainLock.withLock {
            let key = identityKey(address)
            let previous = try vault.get(key).map { try IdentityKey(bytes: $0) }
            try vault.put(key, value.serialize())
            return previous == nil || previous == value ? .newOrUnchanged : .replacedExisting
        }
    }

    public func isTrustedIdentity(
        _ value: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        try identity(for: address, context: context).map { $0 == value } ?? true
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try vault.get(identityKey(address)).map { try IdentityKey(bytes: $0) }
    }

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let data = try vault.get("prekey/\(id)") else {
            throw SignalError.invalidKeyIdentifier("no prekey with this identifier")
        }
        return try PreKeyRecord(bytes: data)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try vault.put("prekey/\(id)", record.serialize())
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws { try vault.delete("prekey/\(id)") }

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let data = try vault.get("signed-prekey/\(id)") else {
            throw SignalError.invalidKeyIdentifier("no signed prekey with this identifier")
        }
        return try SignedPreKeyRecord(bytes: data)
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try vault.put("signed-prekey/\(id)", record.serialize())
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let data = try vault.get("kyber-prekey/\(id)") else {
            throw SignalError.invalidKeyIdentifier("no Kyber prekey with this identifier")
        }
        return try KyberPreKeyRecord(bytes: data)
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try vault.put("kyber-prekey/\(id)", record.serialize())
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        let digest = SHA256.hash(data: baseKey.serialize()).map { String(format: "%02x", $0) }.joined()
        let key = "kyber-used/\(id)/\(signedPreKeyId)/\(digest)"
        try processKeychainLock.withLock {
            if try vault.get(key) != nil { throw SignalError.invalidMessage("reused base key") }
            try vault.put(key, Data([1]))
        }
    }

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try vault.get(sessionKey(address)).map { try SessionRecord(bytes: $0) }
    }

    public func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound("\(address)")
            }
            return record
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try vault.put(sessionKey(address), record.serialize())
    }

    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try vault.put("sender-key/\(addressKey(sender))/\(distributionId.uuidString.lowercased())", record.serialize())
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        try vault.get("sender-key/\(addressKey(sender))/\(distributionId.uuidString.lowercased())")
            .map { try SenderKeyRecord(bytes: $0) }
    }

    public func takeNext(kid: UInt64) throws -> UInt64 { try takeNextCounter(stream: "default", kid: kid) }

    public func takeNextCounter(stream: String, kid: UInt64) throws -> UInt64 {
        try processKeychainLock.withLock {
            let key = "media-counter/\(safe(stream))/\(String(kid, radix: 16))"
            let current = try vault.get(key).map(decodeUInt64) ?? 0
            guard current != UInt64.max else { throw SFrameError.counterExhausted }
            try vault.put(key, encode(current + 1))
            return current
        }
    }

    public func nextRecordId(kind: String) throws -> UInt32 {
        try processKeychainLock.withLock {
            let key = "record-id/\(safe(kind))"
            let current = try vault.get(key).map(decodeUInt32) ?? 1
            guard current != UInt32.max else { throw KeychainStoreError.counterExhausted }
            try vault.put(key, encode(current + 1))
            return current
        }
    }

    public func applicationState(_ key: String) throws -> Data? { try vault.get("app/\(safe(key))") }
    public func putApplicationState(_ key: String, value: Data) throws { try vault.put("app/\(safe(key))", value) }

    public func deleteAllForTesting() throws { try vault.deleteAll() }

    private func identityKey(_ address: ProtocolAddress) -> String { "remote-identity/\(addressKey(address))" }
    private func sessionKey(_ address: ProtocolAddress) -> String { "session/\(addressKey(address))" }
    private func addressKey(_ address: ProtocolAddress) -> String { "\(safe(address.name))/\(address.deviceId)" }
}

public enum KeychainStoreError: Error, Equatable {
    case keychain(OSStatus)
    case corruptRecord
    case counterExhausted
}

private func safe(_ value: String) -> String {
    Data(value.utf8).base64Url
}

private func encode<T: FixedWidthInteger>(_ value: T) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<T>.size)
}

private func decodeUInt32(_ data: Data) throws -> UInt32 {
    guard data.count == 4 else { throw KeychainStoreError.corruptRecord }
    return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func decodeUInt64(_ data: Data) throws -> UInt64 {
    guard data.count == 8 else { throw KeychainStoreError.corruptRecord }
    return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}
