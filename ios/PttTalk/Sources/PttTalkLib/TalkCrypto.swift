import Foundation
import LibSignalClient

/// PQXDH session + 1:1 wrap of the 16-byte media key. Matches `InMemoryCryptoStack`
/// encrypt1to1 / decrypt1to1 / localBundle / processPreKeyBundle.
final class TalkCrypto {
    let aci: UUID
    let localAddress: ProtocolAddress
    let identity: IdentityKeyPair
    let registrationId: UInt32
    let store: InMemorySignalProtocolStore
    let ctx = NullContext()

    private var signedPreKeyId: UInt32 = 1
    private var kyberPreKeyId: UInt32 = 1
    private var nextPreKeyId: UInt32 = 2
    private var unusedOneTime: [UInt32] = []

    init(aci: UUID) throws {
        self.aci = aci
        identity = IdentityKeyPair.generate()
        registrationId = UInt32.random(in: 1...0x3FFF)
        store = InMemorySignalProtocolStore(identity: identity, registrationId: registrationId)
        localAddress = try ProtocolAddress(name: aci.uuidString.lowercased(), deviceId: 1)
        try rotateSignedAndKyber()
        try replenish(minOneTime: 8)
    }

    func address(of peer: UUID) throws -> ProtocolAddress {
        try ProtocolAddress(name: peer.uuidString.lowercased(), deviceId: 1)
    }

    func localBundle() throws -> PreKeyBundleJson {
        let signed = try store.loadSignedPreKey(id: signedPreKeyId, context: ctx)
        let kyber = try store.loadKyberPreKey(id: kyberPreKeyId, context: ctx)
        var preKeyId: Int?
        var preKeyB64: String?
        if let id = unusedOneTime.first {
            unusedOneTime.removeFirst()
            let rec = try store.loadPreKey(id: id, context: ctx)
            preKeyId = Int(id)
            preKeyB64 = BundleJson.b64(try rec.publicKey().serialize())
        }
        return PreKeyBundleJson(
            aci: aci.uuidString.lowercased(),
            deviceId: 1,
            registrationId: Int(registrationId),
            identityKey: BundleJson.b64(identity.identityKey.serialize()),
            signedPreKeyId: Int(signedPreKeyId),
            signedPreKey: BundleJson.b64(try signed.publicKey().serialize()),
            signedPreKeySig: BundleJson.b64(signed.signature),
            preKeyId: preKeyId,
            preKey: preKeyB64,
            kyberPreKeyId: Int(kyberPreKeyId),
            kyberPreKey: BundleJson.b64(try kyber.publicKey().serialize()),
            kyberPreKeySig: BundleJson.b64(kyber.signature)
        )
    }

    func process(peer: UUID, bundle: PreKeyBundleJson) throws {
        let remote = try address(of: peer)
        let identityKey = try IdentityKey(bytes: BundleJson.unb64(bundle.identityKey))
        let signed = try PublicKey(BundleJson.unb64(bundle.signedPreKey))
        let kyber = try KEMPublicKey(BundleJson.unb64(bundle.kyberPreKey))
        let signedSig = try BundleJson.unb64(bundle.signedPreKeySig)
        let kyberSig = try BundleJson.unb64(bundle.kyberPreKeySig)
        let pkb: PreKeyBundle
        if let preId = bundle.preKeyId, let preB64 = bundle.preKey {
            pkb = try PreKeyBundle(
                registrationId: UInt32(bundle.registrationId),
                deviceId: UInt32(bundle.deviceId),
                prekeyId: UInt32(preId),
                prekey: try PublicKey(BundleJson.unb64(preB64)),
                signedPrekeyId: UInt32(bundle.signedPreKeyId),
                signedPrekey: signed,
                signedPrekeySignature: signedSig,
                identity: identityKey,
                kyberPrekeyId: UInt32(bundle.kyberPreKeyId),
                kyberPrekey: kyber,
                kyberPrekeySignature: kyberSig
            )
        } else {
            pkb = try PreKeyBundle(
                registrationId: UInt32(bundle.registrationId),
                deviceId: UInt32(bundle.deviceId),
                signedPrekeyId: UInt32(bundle.signedPreKeyId),
                signedPrekey: signed,
                signedPrekeySignature: signedSig,
                identity: identityKey,
                kyberPrekeyId: UInt32(bundle.kyberPreKeyId),
                kyberPrekey: kyber,
                kyberPrekeySignature: kyberSig
            )
        }
        try processPreKeyBundle(
            pkb,
            for: remote,
            ourAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: ctx
        )
    }

    func encrypt1to1(peer: UUID, plaintext: Data) throws -> Data {
        let remote = try address(of: peer)
        let ct = try signalEncrypt(
            message: plaintext,
            for: remote,
            localAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: ctx
        )
        return ct.serialize()
    }

    func decrypt1to1(sender: UUID, ciphertext: Data) throws -> Data {
        let remote = try address(of: sender)
        do {
            let pre = try PreKeySignalMessage(bytes: ciphertext)
            return try signalDecryptPreKey(
                message: pre,
                from: remote,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: ctx
            )
        } catch {
            let msg = try SignalMessage(bytes: ciphertext)
            return try signalDecrypt(
                message: msg,
                from: remote,
                to: localAddress,
                sessionStore: store,
                identityStore: store,
                context: ctx
            )
        }
    }

    private func rotateSignedAndKyber() throws {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let signedPriv = PrivateKey.generate()
        let signedSig = identity.privateKey.generateSignature(message: signedPriv.publicKey.serialize())
        let signedRec = try SignedPreKeyRecord(
            id: signedPreKeyId,
            timestamp: now,
            privateKey: signedPriv,
            signature: signedSig
        )
        try store.storeSignedPreKey(signedRec, id: signedPreKeyId, context: ctx)

        let kem = KEMKeyPair.generate()
        let kyberSig = identity.privateKey.generateSignature(message: kem.publicKey.serialize())
        let kyberRec = try KyberPreKeyRecord(
            id: kyberPreKeyId,
            timestamp: now,
            keyPair: kem,
            signature: kyberSig
        )
        try store.storeKyberPreKey(kyberRec, id: kyberPreKeyId, context: ctx)
    }

    private func replenish(minOneTime: Int) throws {
        while unusedOneTime.count < minOneTime {
            let id = nextPreKeyId
            nextPreKeyId += 1
            let rec = try PreKeyRecord(id: id, privateKey: PrivateKey.generate())
            try store.storePreKey(rec, id: id, context: ctx)
            unusedOneTime.append(id)
        }
    }
}
