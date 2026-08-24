package app.ptt.talk

import android.content.Context
import android.util.Base64
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.nio.ByteBuffer
import java.time.Duration
import java.time.Instant
import java.util.UUID
import org.json.JSONObject
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.InvalidMessageException
import org.signal.libsignal.protocol.InvalidVersionException
import org.signal.libsignal.protocol.LegacyMessageException
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

internal data class MediaEpochAnnouncement(
    val channelId: UUID,
    val talkId: UUID,
    val membershipEpoch: Int,
    val senderDemux: Long,
    val kid: ULong,
    val baseKey: ByteArray,
    val totMs: Int,
    val isSos: Boolean = false,
)

internal data class OpenedPairwiseEnvelope(
    val senderAci: String,
    val senderDeviceId: Int,
    val announcement: MediaEpochAnnouncement,
)

/** Durable libsignal PQXDH/Double-Ratchet operations over the encrypted SQLCipher store. */
internal class PersistentPairwiseCrypto(context: Context, private val session: DeviceSession) {
    private val app = context.applicationContext
    private val api = ControlApi(session.serverUrl)

    @Synchronized
    fun ensurePreKeysPublished(
        now: Instant = Instant.now(),
        initialBatchSize: Int = 100,
        replenishmentBatchSize: Int = 20,
    ) {
        require(initialBatchSize in 1..100 && replenishmentBatchSize in 1..100)
        EncryptedSignalProtocolStore.open(app).use { store ->
            val last =
                store.applicationState(PREKEY_PUBLISHED_AT)
                    ?.decodeToString()
                    ?.let { encoded -> runCatching { Instant.parse(encoded) }.getOrNull() }
            if (last != null && Duration.between(last, now) < PREKEY_REPLENISH_INTERVAL) return
            val descriptor = baseDescriptor(store)
            val count = if (last == null) initialBatchSize else replenishmentBatchSize
            val keys = ArrayList<OneTimePreKeyUpload>(count * 2)
            repeat(count) {
                val ecId = store.nextApplicationRecordId("ec-prekey")
                val ec = ECKeyPair.generate()
                store.storePreKey(ecId, PreKeyRecord(ecId, ec))
                keys += OneTimePreKeyUpload("x25519", ecId, ec.publicKey.serialize())

                val kyberId = store.nextApplicationRecordId("kyber-prekey")
                val kyber = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
                val signature = store.identityKeyPair.privateKey.calculateSignature(kyber.publicKey.serialize())
                store.storeKyberPreKey(
                    kyberId,
                    KyberPreKeyRecord(kyberId, now.toEpochMilli(), kyber, signature),
                )
                keys += OneTimePreKeyUpload("kyber", kyberId, encodeKyberOneTime(kyber.publicKey.serialize(), signature))
            }
            api.uploadPreKeys(session, descriptor, keys)
            store.putApplicationState(PREKEY_PUBLISHED_AT, now.toString().encodeToByteArray())
        }
    }

    @Synchronized
    fun encryptFor(device: ChannelDevice, plaintext: ByteArray): ByteArray {
        require(device.aci != session.aci || device.deviceId != session.deviceId) {
            "cannot create a pairwise envelope for the local device"
        }
        EncryptedSignalProtocolStore.open(app).use { store ->
            val remote = SignalProtocolAddress(device.aci, device.deviceId)
            val local = SignalProtocolAddress(session.aci, session.deviceId)
            if (!store.containsSession(remote)) {
                val fetched =
                    api.fetchPreKeys(session, listOf(device.aci to device.deviceId)).singleOrNull()
                        ?: error("recipient has not published prekeys")
                val descriptor = PreKeyDescriptor.decode(fetched.opaqueBundle)
                require(descriptor.identityKey.contentEquals(device.identityKey)) {
                    "prekey identity does not match channel membership"
                }
                SessionBuilder(store, remote, local).process(fetched.toLibsignalBundle(descriptor))
            }
            val ciphertext = SessionCipher(store, local, remote).encrypt(plaintext).serialize()
            return encodeOuterEnvelope(session.aci, session.deviceId, ciphertext)
        }
    }

    @Synchronized
    fun decryptEnvelope(
        envelope: ByteArray,
        allowedDevices: List<ChannelDevice>? = null,
    ): OpenedPairwiseEnvelope {
        val outer = decodeOuterEnvelope(envelope)
        val expected =
            allowedDevices?.singleOrNull {
                it.aci == outer.senderAci && it.deviceId == outer.senderDeviceId
            }
        if (allowedDevices != null) requireNotNull(expected) { "sender is not an active channel device" }
        EncryptedSignalProtocolStore.open(app).use { store ->
            val local = SignalProtocolAddress(session.aci, session.deviceId)
            val sender = SignalProtocolAddress(outer.senderAci, outer.senderDeviceId)
            val cipher = SessionCipher(store, local, sender)
            val plaintext =
                try {
                    cipher.decrypt(PreKeySignalMessage(outer.ciphertext))
                } catch (_: InvalidMessageException) {
                    cipher.decrypt(SignalMessage(outer.ciphertext))
                } catch (_: InvalidVersionException) {
                    cipher.decrypt(SignalMessage(outer.ciphertext))
                } catch (_: LegacyMessageException) {
                    cipher.decrypt(SignalMessage(outer.ciphertext))
                }
            if (expected != null) {
                val established = requireNotNull(store.getIdentity(sender)) { "sender identity was not established" }
                require(established.serialize().contentEquals(expected.identityKey)) {
                    "sender identity does not match channel membership"
                }
            }
            return OpenedPairwiseEnvelope(
                outer.senderAci,
                outer.senderDeviceId,
                decodeAnnouncement(plaintext),
            )
        }
    }

    fun announceMediaEpoch(
        devices: List<ChannelDevice>,
        announcement: MediaEpochAnnouncement,
    ): Int {
        val plaintext = encodeAnnouncement(announcement)
        val recipients =
            devices.filterNot { it.aci == session.aci && it.deviceId == session.deviceId }.map { device ->
                MailboxRecipient(device.aci, device.deviceId, encryptFor(device, plaintext))
            }
        if (recipients.isEmpty()) return 0
        return api.enqueueMailbox(
            session,
            announcement.talkId.toString(),
            recipients,
            Instant.now().plusSeconds(5 * 60),
        )
    }

    private fun baseDescriptor(store: EncryptedSignalProtocolStore): ByteArray {
        store.applicationState(BASE_DESCRIPTOR)?.let { return it }
        val now = System.currentTimeMillis()
        val signedId = store.nextApplicationRecordId("signed-prekey")
        val signedPair = ECKeyPair.generate()
        val signedSignature = store.identityKeyPair.privateKey.calculateSignature(signedPair.publicKey.serialize())
        store.storeSignedPreKey(
            signedId,
            SignedPreKeyRecord(signedId, now, signedPair, signedSignature),
        )
        val kyberId = store.nextApplicationRecordId("last-resort-kyber")
        val kyberPair = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberSignature = store.identityKeyPair.privateKey.calculateSignature(kyberPair.publicKey.serialize())
        store.storeKyberPreKey(
            kyberId,
            KyberPreKeyRecord(kyberId, now, kyberPair, kyberSignature),
        )
        return PreKeyDescriptor(
            registrationId = store.localRegistrationId,
            identityKey = store.identityKeyPair.publicKey.serialize(),
            signedPreKeyId = signedId,
            signedPreKey = signedPair.publicKey.serialize(),
            signedPreKeySignature = signedSignature,
            lastResortKyberId = kyberId,
            lastResortKyber = kyberPair.publicKey.serialize(),
            lastResortKyberSignature = kyberSignature,
        ).encode().also { store.putApplicationState(BASE_DESCRIPTOR, it) }
    }

    private data class OuterEnvelope(
        val senderAci: String,
        val senderDeviceId: Int,
        val ciphertext: ByteArray,
    )

    private fun FetchedPreKey.toLibsignalBundle(descriptor: PreKeyDescriptor): PreKeyBundle {
        val ec = oneTimePreKeys.firstOrNull { it.kind == "x25519" }
        val kyber = oneTimePreKeys.firstOrNull { it.kind == "kyber" }
        val kyberDecoded = kyber?.publicKey?.let(::decodeKyberOneTime)
        return PreKeyBundle(
            descriptor.registrationId,
            deviceId,
            ec?.keyId ?: PreKeyBundle.NULL_PRE_KEY_ID,
            ec?.publicKey?.let(::ECPublicKey),
            descriptor.signedPreKeyId,
            ECPublicKey(descriptor.signedPreKey),
            descriptor.signedPreKeySignature,
            IdentityKey(descriptor.identityKey),
            kyber?.keyId ?: descriptor.lastResortKyberId,
            KEMPublicKey(kyberDecoded?.first ?: descriptor.lastResortKyber),
            kyberDecoded?.second ?: descriptor.lastResortKyberSignature,
        )
    }

    private companion object {
        const val BASE_DESCRIPTOR = "prekey-base-v1"
        const val PREKEY_PUBLISHED_AT = "prekeys-published-at"
        val PREKEY_REPLENISH_INTERVAL: Duration = Duration.ofHours(24)
        val OUTER_MAGIC = "PTTE".encodeToByteArray()
        val ANNOUNCEMENT_MAGIC = "PTTM".encodeToByteArray()

        fun encodeOuterEnvelope(senderAci: String, senderDeviceId: Int, ciphertext: ByteArray): ByteArray {
            require(senderDeviceId in 1..2 && ciphertext.isNotEmpty())
            val aci = UUID.fromString(senderAci)
            return ByteBuffer.allocate(4 + 1 + 16 + 1 + ciphertext.size)
                .put(OUTER_MAGIC)
                .put(1)
                .putLong(aci.mostSignificantBits)
                .putLong(aci.leastSignificantBits)
                .put(senderDeviceId.toByte())
                .put(ciphertext)
                .array()
        }

        fun decodeOuterEnvelope(bytes: ByteArray): OuterEnvelope {
            require(bytes.size > 22) { "pairwise envelope is truncated" }
            val buffer = ByteBuffer.wrap(bytes)
            val magic = ByteArray(4).also(buffer::get)
            require(magic.contentEquals(OUTER_MAGIC) && buffer.get().toInt() == 1) {
                "unsupported pairwise envelope"
            }
            val sender = UUID(buffer.long, buffer.long).toString()
            val device = buffer.get().toInt() and 0xff
            require(device in 1..2)
            return OuterEnvelope(sender, device, ByteArray(buffer.remaining()).also(buffer::get))
        }

        fun encodeAnnouncement(value: MediaEpochAnnouncement): ByteArray {
            require(value.membershipEpoch > 0 && value.senderDemux in 1..0xffff_ffffL)
            require(value.baseKey.size == 32 && value.totMs in 1..60_000)
            return ByteBuffer.allocate(4 + 1 + 1 + 16 + 16 + 4 + 4 + 8 + 4 + 32)
                .put(ANNOUNCEMENT_MAGIC)
                .put(2)
                .put(if (value.isSos) 1.toByte() else 0.toByte())
                .putLong(value.channelId.mostSignificantBits)
                .putLong(value.channelId.leastSignificantBits)
                .putLong(value.talkId.mostSignificantBits)
                .putLong(value.talkId.leastSignificantBits)
                .putInt(value.membershipEpoch)
                .putInt(value.senderDemux.toInt())
                .putLong(value.kid.toLong())
                .putInt(value.totMs)
                .put(value.baseKey)
                .array()
        }

        fun decodeAnnouncement(bytes: ByteArray): MediaEpochAnnouncement {
            require(bytes.size == 89 || bytes.size == 90) { "invalid media announcement length" }
            val buffer = ByteBuffer.wrap(bytes)
            val magic = ByteArray(4).also(buffer::get)
            val version = buffer.get().toInt()
            require(magic.contentEquals(ANNOUNCEMENT_MAGIC) && version in 1..2)
            val flags = if (version == 2) buffer.get().toInt() and 0xff else 0
            require(flags and 0xfe == 0)
            val channel = UUID(buffer.long, buffer.long)
            val talk = UUID(buffer.long, buffer.long)
            val epoch = buffer.int
            val demux = buffer.int.toLong() and 0xffff_ffffL
            val kid = buffer.long.toULong()
            val tot = buffer.int
            val key = ByteArray(32).also(buffer::get)
            require(epoch > 0 && demux > 0 && tot in 1..60_000)
            return MediaEpochAnnouncement(channel, talk, epoch, demux, kid, key, tot, flags and 1 != 0)
        }

        fun encodeKyberOneTime(publicKey: ByteArray, signature: ByteArray): ByteArray =
            JSONObject()
                .put("version", 1)
                .put("publicKey", publicKey.base64Url())
                .put("signature", signature.base64Url())
                .toString()
                .encodeToByteArray()

        fun decodeKyberOneTime(bytes: ByteArray): Pair<ByteArray, ByteArray> {
            val value = JSONObject(bytes.decodeToString())
            require(value.getInt("version") == 1)
            return value.getString("publicKey").base64UrlBytes() to
                value.getString("signature").base64UrlBytes()
        }

        fun ByteArray.base64Url(): String =
            Base64.encodeToString(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        fun String.base64UrlBytes(): ByteArray =
            Base64.decode(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }
}

private data class PreKeyDescriptor(
    val registrationId: Int,
    val identityKey: ByteArray,
    val signedPreKeyId: Int,
    val signedPreKey: ByteArray,
    val signedPreKeySignature: ByteArray,
    val lastResortKyberId: Int,
    val lastResortKyber: ByteArray,
    val lastResortKyberSignature: ByteArray,
) {
    fun encode(): ByteArray =
        JSONObject()
            .put("version", 1)
            .put("registrationId", registrationId)
            .put("identityKey", identityKey.base64Url())
            .put("signedPreKeyId", signedPreKeyId)
            .put("signedPreKey", signedPreKey.base64Url())
            .put("signedPreKeySignature", signedPreKeySignature.base64Url())
            .put("lastResortKyberId", lastResortKyberId)
            .put("lastResortKyber", lastResortKyber.base64Url())
            .put("lastResortKyberSignature", lastResortKyberSignature.base64Url())
            .toString()
            .encodeToByteArray()

    companion object {
        fun decode(bytes: ByteArray): PreKeyDescriptor {
            val value = JSONObject(bytes.decodeToString())
            require(value.getInt("version") == 1)
            return PreKeyDescriptor(
                value.getInt("registrationId"),
                value.getString("identityKey").base64UrlBytes(),
                value.getInt("signedPreKeyId"),
                value.getString("signedPreKey").base64UrlBytes(),
                value.getString("signedPreKeySignature").base64UrlBytes(),
                value.getInt("lastResortKyberId"),
                value.getString("lastResortKyber").base64UrlBytes(),
                value.getString("lastResortKyberSignature").base64UrlBytes(),
            )
        }

        private fun ByteArray.base64Url(): String =
            Base64.encodeToString(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        private fun String.base64UrlBytes(): ByteArray =
            Base64.decode(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }
}
