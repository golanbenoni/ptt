import Foundation
import LibSignalClient
import Testing
@testable import PttTalkLib

@Test func secureDeviceSessionSurvivesStoreRecreation() throws {
    let namespace = "app.ptt.talk.tests.session.\(UUID().uuidString)"
    let store = SecureDeviceStore(namespace: namespace)
    defer { try? store.clear() }
    let value = DeviceSession(
        serverUrl: "https://ptt.example",
        aci: UUID().uuidString.lowercased(),
        deviceId: 2,
        mailboxId: UUID().uuidString.lowercased(),
        accessToken: "secret"
    )
    try store.save(session: value)
    #expect(try SecureDeviceStore(namespace: namespace).loadSession() == value)
}

@Test func signalIdentityRecordsAndCountersAreDurable() throws {
    let namespace = "app.ptt.talk.tests.signal.\(UUID().uuidString)"
    let first = try KeychainSignalProtocolStore(namespace: namespace)
    defer { try? first.deleteAllForTesting() }
    let identity = first.identityPublicKey
    let registration = try first.localRegistrationId(context: NullContext())
    #expect(try first.takeNextCounter(stream: "channel/device", kid: 9) == 0)
    #expect(try first.nextRecordId(kind: "prekey") == 1)

    let second = try KeychainSignalProtocolStore(namespace: namespace)
    #expect(second.identityPublicKey == identity)
    #expect(try second.localRegistrationId(context: NullContext()) == registration)
    #expect(try second.takeNextCounter(stream: "channel/device", kid: 9) == 1)
    #expect(try second.nextRecordId(kind: "prekey") == 2)
}

@Test func signalRemoteIdentityPinningPersists() throws {
    let namespace = "app.ptt.talk.tests.identity.\(UUID().uuidString)"
    let store = try KeychainSignalProtocolStore(namespace: namespace)
    defer { try? store.deleteAllForTesting() }
    let address = try ProtocolAddress(name: UUID().uuidString.lowercased(), deviceId: 1)
    let identity = IdentityKeyPair.generate().identityKey
    #expect(try store.saveIdentity(identity, for: address, context: NullContext()) == .newOrUnchanged)

    let reopened = try KeychainSignalProtocolStore(namespace: namespace)
    #expect(try reopened.identity(for: address, context: NullContext()) == identity)
    #expect(try reopened.isTrustedIdentity(identity, for: address, direction: .sending, context: NullContext()))
    #expect(try !reopened.isTrustedIdentity(
        IdentityKeyPair.generate().identityKey,
        for: address,
        direction: .sending,
        context: NullContext()
    ))
}
