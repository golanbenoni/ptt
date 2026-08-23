package app.ptt.crypto

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlin.math.max
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.signal.libsignal.metadata.SealedSessionCipher
import org.signal.libsignal.metadata.certificate.SenderCertificate
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidMessageException
import org.signal.libsignal.protocol.InvalidVersionException
import org.signal.libsignal.protocol.LegacyMessageException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator
import org.signal.libsignal.protocol.groups.GroupCipher
import org.signal.libsignal.protocol.groups.GroupSessionBuilder
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SenderKeyDistributionMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord
import org.signal.libsignal.protocol.state.impl.InMemorySignalProtocolStore
import org.signal.libsignal.protocol.util.KeyHelper

/**
 * PR1 CryptoStack: libsignal InMemory* stores + PQXDH (Kyber-1024 in the prekey bundle).
 *
 * Session operations are serialized on [sessionLock]. Callers are not thread-safe
 * across a single instance except through this lock.
 */
class InMemoryCryptoStack : CryptoStack {
    private val sessionLock = Mutex()
    private val random = SecureRandom()

    private var identity: IdentityKeyPair? = null
    private var registrationId: Int = 0
    private var profileKey: ByteArray = ByteArray(0)
    private var aci: Aci? = null
    private var store: InMemorySignalProtocolStore? = null

    private var nextPreKeyId = 1
    private var nextKyberId = 1
    private var currentSignedPreKeyId = 0
    private var currentKyberPreKeyId = 0
    private val unusedOneTimePreKeyIds = LinkedHashSet<Int>()
    private val unusedOneTimeKyberIds = LinkedHashSet<Int>()

    private data class ChannelKeys(
        var distributionId: UUID,
        var skdm: ByteArray,
        var secret: ByteArray,
    )

    private val channels = mutableMapOf<ChannelId, ChannelKeys>()
    private var authority: TestCertificateAuthority? = null
    private var senderCert: SenderCertificate? = null

    override suspend fun generateIdentity(): IdentityInfo {
        sessionLock.withLock {
            val pair = IdentityKeyPair.generate()
            val regId = KeyHelper.generateRegistrationId(false)
            val profile = ByteArray(32).also { random.nextBytes(it) }
            identity = pair
            registrationId = regId
            profileKey = profile
            store = InMemorySignalProtocolStore(pair, regId)
            nextPreKeyId = 1
            nextKyberId = 1
            unusedOneTimePreKeyIds.clear()
            unusedOneTimeKyberIds.clear()
            channels.clear()
            senderCert = null
            currentSignedPreKeyId = 0
            currentKyberPreKeyId = 0
            rotateSignedAndKyberLocked()
            return IdentityInfo(
                aci = aci,
                registrationId = regId,
                identityKeyPublic = pair.publicKey.serialize(),
                profileKey = profile.copyOf(),
            )
        }
    }

    override fun setAci(aci: Aci) {
        this.aci = aci
    }

    override suspend fun replenishPreKeys(minOneTime: Int) {
        sessionLock.withLock {
            val st = requireStore()
            val pair = requireIdentity()
            while (unusedOneTimePreKeyIds.size < minOneTime) {
                val id = nextPreKeyId++
                val kp = ECKeyPair.generate()
                st.storePreKey(id, PreKeyRecord(id, kp))
                unusedOneTimePreKeyIds.add(id)
            }
            while (unusedOneTimeKyberIds.size < minOneTime) {
                val id = nextKyberId++
                val kem = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
                val sig = pair.privateKey.calculateSignature(kem.publicKey.serialize())
                st.storeKyberPreKey(id, KyberPreKeyRecord(id, System.currentTimeMillis(), kem, sig))
                unusedOneTimeKyberIds.add(id)
            }
        }
    }

    override suspend fun localBundle(): PreKeyBundleDto {
        sessionLock.withLock {
            val st = requireStore()
            val pair = requireIdentity()
            val localAci = aci ?: throw IllegalStateException("setAci before localBundle")
            if (currentSignedPreKeyId == 0 || currentKyberPreKeyId == 0) {
                rotateSignedAndKyberLocked()
            }
            val signed = st.loadSignedPreKey(currentSignedPreKeyId)
            val kyber = st.loadKyberPreKey(currentKyberPreKeyId)
            val oneTimeId = unusedOneTimePreKeyIds.firstOrNull()
            if (oneTimeId != null) unusedOneTimePreKeyIds.remove(oneTimeId)
            val oneTime = oneTimeId?.let { st.loadPreKey(it) }
            return PreKeyBundleDto(
                aci = localAci,
                deviceId = 1,
                registrationId = registrationId,
                identityKey = pair.publicKey.serialize(),
                signedPreKeyId = currentSignedPreKeyId,
                signedPreKey = signed.keyPair.publicKey.serialize(),
                signedPreKeySig = signed.signature,
                preKeyId = oneTimeId,
                preKey = oneTime?.keyPair?.publicKey?.serialize(),
                kyberPreKeyId = currentKyberPreKeyId,
                kyberPreKey = kyber.keyPair.publicKey.serialize(),
                kyberPreKeySig = kyber.signature,
            )
        }
    }

    override suspend fun processPreKeyBundle(peer: DeviceId, bundle: PreKeyBundleDto) {
        sessionLock.withLock {
            val st = requireStore()
            val local = localAddress()
            val remote = address(peer)
            val preKey =
                PreKeyBundle(
                    bundle.registrationId,
                    bundle.deviceId,
                    bundle.preKeyId ?: PreKeyBundle.NULL_PRE_KEY_ID,
                    bundle.preKey?.let { ECPublicKey(it) },
                    bundle.signedPreKeyId,
                    ECPublicKey(bundle.signedPreKey),
                    bundle.signedPreKeySig,
                    IdentityKey(bundle.identityKey),
                    bundle.kyberPreKeyId,
                    KEMPublicKey(bundle.kyberPreKey),
                    bundle.kyberPreKeySig,
                )
            SessionBuilder(st, remote, local).process(preKey)
        }
    }

    override suspend fun encrypt1to1(peer: DeviceId, plaintext: ByteArray): ByteArray {
        sessionLock.withLock {
            val st = requireStore()
            if (!st.containsSession(address(peer))) {
                throw NoSessionException("no session for $peer")
            }
            val cipher = SessionCipher(st, localAddress(), address(peer))
            return cipher.encrypt(plaintext).serialize()
        }
    }

    override suspend fun decrypt1to1(sender: DeviceId, ciphertext: ByteArray): ByteArray {
        sessionLock.withLock {
            val st = requireStore()
            val cipher = SessionCipher(st, localAddress(), address(sender))
            return try {
                cipher.decrypt(PreKeySignalMessage(ciphertext))
            } catch (_: InvalidMessageException) {
                cipher.decrypt(SignalMessage(ciphertext))
            } catch (_: InvalidVersionException) {
                cipher.decrypt(SignalMessage(ciphertext))
            } catch (_: LegacyMessageException) {
                cipher.decrypt(SignalMessage(ciphertext))
            }
        }
    }

    override fun localDevice(): DeviceId {
        val localAci = aci ?: throw IllegalStateException("setAci first")
        return DeviceId(localAci)
    }

    override fun attachTestAuthority(authority: TestCertificateAuthority) {
        this.authority = authority
        val pair = identity ?: return
        val localAci = aci ?: return
        senderCert = authority.issue(localAci.uuid, 1, pair.publicKey.publicKey)
    }

    override fun channelSecret(channel: ChannelId): ByteArray =
        channels[channel]?.secret?.copyOf()
            ?: throw IllegalStateException("no channel $channel")

    override suspend fun seal(recipients: List<DeviceId>, content: ByteArray): SealedResult {
        sessionLock.withLock {
            val st = requireStore()
            val cert = senderCert
            if (cert == null) {
                return SealedResult(emptyList(), recipients.toList())
            }
            val warm = recipients.filter { st.containsSession(address(it)) }
            val fallback = recipients.filterNot { st.containsSession(address(it)) }
            if (warm.isEmpty()) {
                return SealedResult(emptyList(), fallback)
            }
            val sealed = sealedCipher()
            val envelopes = mutableListOf<SealedEnvelope>()
            for (chunk in warm.chunked(SSV2_CHUNK)) {
                for (r in chunk) {
                    val outer = sealed.encrypt(address(r), cert, content)
                    envelopes += SealedEnvelope(outer, listOf(uuidBytes(r.aci.uuid)))
                }
            }
            return SealedResult(envelopes, fallback)
        }
    }

    override suspend fun open(envelope: ByteArray): Opened {
        sessionLock.withLock {
            val auth = authority ?: throw IllegalStateException("attachTestAuthority first")
            val sealed = sealedCipher()
            val result = sealed.decrypt(auth.validator(), envelope, System.currentTimeMillis())
            val uuid = UUID.fromString(result.senderUuid)
            return Opened(
                sender = DeviceId(Aci(uuid), result.deviceId),
                inner = unpad(result.paddedMessage),
            )
        }
    }

    override suspend fun createSenderKeyDistribution(channel: ChannelId): ByteArray {
        sessionLock.withLock {
            val st = requireStore()
            val existing = channels[channel]
            if (existing != null && existing.skdm.isNotEmpty()) {
                return existing.skdm.copyOf()
            }
            val dist = UUID.randomUUID()
            val skdm = GroupSessionBuilder(st).create(localAddress(), dist).serialize()
            require(skdm.isNotEmpty()) { "empty SKDM" }
            val secret = existing?.secret ?: ByteArray(32).also { random.nextBytes(it) }
            channels[channel] = ChannelKeys(dist, skdm, secret)
            return skdm.copyOf()
        }
    }

    override suspend fun processSenderKeyDistribution(
        sender: DeviceId,
        channel: ChannelId,
        skdm: ByteArray,
    ) {
        sessionLock.withLock {
            val st = requireStore()
            val msg = SenderKeyDistributionMessage(skdm)
            GroupSessionBuilder(st).process(address(sender), msg)
        }
    }

    override suspend fun rotateSenderKey(channel: ChannelId): UUID {
        sessionLock.withLock {
            val st = requireStore()
            val dist = UUID.randomUUID()
            val skdm = GroupSessionBuilder(st).create(localAddress(), dist).serialize()
            val secret = ByteArray(32).also { random.nextBytes(it) }
            channels[channel] = ChannelKeys(dist, skdm, secret)
            return dist
        }
    }

    override suspend fun groupEncrypt(channel: ChannelId, plaintext: ByteArray): ByteArray {
        sessionLock.withLock {
            val st = requireStore()
            val keys = channels[channel] ?: throw NoSessionException("no sender key for $channel")
            return GroupCipher(st, localAddress()).encrypt(keys.distributionId, plaintext).serialize()
        }
    }

    override suspend fun groupDecrypt(
        sender: DeviceId,
        channel: ChannelId,
        ciphertext: ByteArray,
    ): ByteArray {
        sessionLock.withLock {
            val st = requireStore()
            return GroupCipher(st, address(sender)).decrypt(ciphertext)
        }
    }

    override fun encodeTalkStart(decision: FloorDecision, epoch: MediaEpoch): ByteArray =
        TalkStartCodec.encode(decision, epoch)

    override fun decodeTalkStart(plaintext: ByteArray): Pair<FloorDecision, MediaEpoch> {
        val (d, e, _) = TalkStartCodec.decode(plaintext)
        return d to e
    }

    override suspend fun wrapMediaEpoch(channel: ChannelId, epoch: MediaEpoch): ByteArray =
        groupEncrypt(channel, encodeTalkStart(
            FloorDecision(ByteArray(16), epoch.talkId, 30_000, epoch.kid, epoch.senderDemux),
            epoch,
        ))

    override suspend fun unwrapMediaEpoch(
        sender: DeviceId,
        channel: ChannelId,
        ciphertext: ByteArray,
    ): MediaEpoch = decodeTalkStart(groupDecrypt(sender, channel, ciphertext)).second

    override fun safetyNumber1to1(peer: Aci): String {
        val st = store ?: throw IllegalStateException("generateIdentity first")
        val localAci = aci ?: throw IllegalStateException("setAci first")
        val localPair = identity ?: throw IllegalStateException("generateIdentity first")
        val remoteAddr = address(DeviceId(peer))
        val remoteIdentity =
            st.getIdentity(remoteAddr)
                ?: throw IllegalStateException("no identity for $peer; process a bundle first")
        val gen = NumericFingerprintGenerator(FINGERPRINT_ITERATIONS)
        val fp =
            gen.createFor(
                FINGERPRINT_VERSION,
                uuidBytes(localAci.uuid),
                localPair.publicKey,
                uuidBytes(peer.uuid),
                remoteIdentity,
            )
        return fp.displayableFingerprint.displayText
    }

    override fun safetyNumberChannel(
        channel: ChannelId,
        memberIdentityKeys: List<ByteArray>,
    ): String {
        val md = MessageDigest.getInstance("SHA-512")
        md.update(CHANNEL_FINGERPRINT_VERSION)
        md.update(uuidBytes(channel.uuid))
        memberIdentityKeys.sortedWith { a, b ->
            val n = minOf(a.size, b.size)
            for (i in 0 until n) {
                val c = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
                if (c != 0) return@sortedWith c
            }
            a.size - b.size
        }.forEach { md.update(it) }
        val digits =
            BigInteger(1, md.digest())
                .mod(CHANNEL_FINGERPRINT_MODULUS)
                .toString()
                .padStart(CHANNEL_FINGERPRINT_DIGITS, '0')
        return digits.chunked(CHANNEL_FINGERPRINT_GROUP_DIGITS).joinToString(" ")
    }

    private fun rotateSignedAndKyberLocked() {
        val st = requireStore()
        val pair = requireIdentity()
        val signedId = max(1, currentSignedPreKeyId + 1)
        val signedKp = ECKeyPair.generate()
        val signedSig = pair.privateKey.calculateSignature(signedKp.publicKey.serialize())
        st.storeSignedPreKey(
            signedId,
            SignedPreKeyRecord(signedId, System.currentTimeMillis(), signedKp, signedSig),
        )
        currentSignedPreKeyId = signedId

        val kyberId = max(1, currentKyberPreKeyId + 1)
        val kem = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberSig = pair.privateKey.calculateSignature(kem.publicKey.serialize())
        st.storeKyberPreKey(
            kyberId,
            KyberPreKeyRecord(kyberId, System.currentTimeMillis(), kem, kyberSig),
        )
        currentKyberPreKeyId = kyberId
        nextKyberId = max(nextKyberId, kyberId + 1)
    }

    private fun requireStore(): InMemorySignalProtocolStore =
        store ?: throw IllegalStateException("generateIdentity first")

    private fun requireIdentity(): IdentityKeyPair =
        identity ?: throw IllegalStateException("generateIdentity first")

    private fun localAddress(): SignalProtocolAddress {
        val localAci = aci ?: throw IllegalStateException("setAci first")
        return address(DeviceId(localAci))
    }

    private fun address(id: DeviceId): SignalProtocolAddress =
        SignalProtocolAddress(id.aci.uuid.toString(), id.deviceId)

    private fun sealedCipher(): SealedSessionCipher {
        val localAci = aci ?: throw IllegalStateException("setAci first")
        return SealedSessionCipher(requireStore(), localAci.uuid, "", 1)
    }

    companion object {
        private const val FINGERPRINT_ITERATIONS = 5200
        private const val FINGERPRINT_VERSION = 2
        private const val SSV2_CHUNK = 100
        private const val CHANNEL_FINGERPRINT_VERSION: Byte = 0x01
        private const val CHANNEL_FINGERPRINT_DIGITS = 60
        private const val CHANNEL_FINGERPRINT_GROUP_DIGITS = 5
        private val CHANNEL_FINGERPRINT_MODULUS = BigInteger.TEN.pow(CHANNEL_FINGERPRINT_DIGITS)

        internal fun unpad(padded: ByteArray): ByteArray {
            var i = padded.size - 1
            while (i >= 0 && padded[i] == 0.toByte()) i--
            if (i >= 0 && padded[i] == 0x80.toByte()) {
                return padded.copyOf(i)
            }
            return padded
        }

        internal fun uuidBytes(uuid: UUID): ByteArray {
            val buf = ByteBuffer.allocate(16)
            buf.putLong(uuid.mostSignificantBits)
            buf.putLong(uuid.leastSignificantBits)
            return buf.array()
        }
    }
}
