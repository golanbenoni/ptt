package app.ptt.crypto

import java.util.UUID

@JvmInline
value class Aci(val uuid: UUID)

@JvmInline
value class ChannelId(val uuid: UUID)

@JvmInline
value class MailboxId(val uuid: UUID)

data class DeviceId(val aci: Aci, val deviceId: Int = 1) {
    init {
        require(deviceId in 1..2) { "production voice v1 supports device ids 1 and 2" }
    }
}

data class RecipientDevice(
    val address: DeviceId,
    val mailboxId: MailboxId,
)

enum class DeviceStatus {
    PENDING,
    ACTIVE,
    REVOKED,
}

data class AccountDevice(
    val address: DeviceId,
    val mailboxId: MailboxId,
    val displayName: String,
    val status: DeviceStatus,
)

enum class CipherSuite {
    AES_128_GCM_SHA256_128,
    AES_256_GCM_SHA512_128,
}

data class MediaEpoch(
    val talkId: UUID,
    val epoch: Int,
    val kid: Long,
    val baseKey: ByteArray,
    val suite: CipherSuite,
    val graceMs: Int,
    val senderDemux: Int,
    val channelId: ChannelId,
)

data class FloorDecision(
    val requestToken: ByteArray,
    val talkId: UUID,
    val totMs: Int,
    val mediaEpochKid: Long,
    val senderDemux: Int,
)

data class UnidentifiedAccess(
    val uak: ByteArray,
    val senderCertificate: ByteArray,
)

data class SealedEnvelope(
    val outer: ByteArray,
    val recipientMailboxes: List<ByteArray>,
)

data class SealedResult(
    val envelopes: List<SealedEnvelope>,
    val identifiedFallback: List<RecipientDevice>,
)

data class Opened(
    val sender: DeviceId,
    val inner: ByteArray,
)

data class PreKeyBundleDto(
    val aci: Aci,
    val deviceId: Int,
    val registrationId: Int,
    val identityKey: ByteArray,
    val signedPreKeyId: Int,
    val signedPreKey: ByteArray,
    val signedPreKeySig: ByteArray,
    val preKeyId: Int?,
    val preKey: ByteArray?,
    val kyberPreKeyId: Int,
    val kyberPreKey: ByteArray,
    val kyberPreKeySig: ByteArray,
)

data class IdentityInfo(
    val aci: Aci?,
    val registrationId: Int,
    val identityKeyPublic: ByteArray,
    val profileKey: ByteArray,
)

/**
 * Signal-protocol facade for PTT.
 *
 * PR2: sender keys, TalkStart, SSv2 seal/open (test CA), channel fingerprint.
 *
 * [PQXDH_INFO] is the application identifier required by the PQXDH spec §2.1
 * (ASCII ≥ 8 bytes). libsignal 0.101 bakes its own info into the native
 * PQXDH handshake; we still freeze this string as our domain separator for
 * application-level HKDF (profile keys, later media wraps) and as the value
 * we will pass if/when the Java API exposes a custom info.
 */
interface CryptoStack {
    companion object {
        const val PQXDH_INFO = "PTT-PQXDH-v1"
    }

    suspend fun generateIdentity(): IdentityInfo

    /** Registration and tests. PR1 has no network; tests call this with random UUIDs. */
    fun setAci(aci: Aci)

    fun debugSetAci(aci: Aci) = setAci(aci)

    suspend fun replenishPreKeys(minOneTime: Int = 100)

    suspend fun localBundle(): PreKeyBundleDto

    suspend fun processPreKeyBundle(peer: DeviceId, bundle: PreKeyBundleDto)

    suspend fun encrypt1to1(peer: DeviceId, plaintext: ByteArray): ByteArray

    suspend fun decrypt1to1(sender: DeviceId, ciphertext: ByteArray): ByteArray

    suspend fun seal(recipients: List<RecipientDevice>, content: ByteArray): SealedResult

    suspend fun open(envelope: ByteArray): Opened

    suspend fun createSenderKeyDistribution(channel: ChannelId): ByteArray

    suspend fun processSenderKeyDistribution(
        sender: DeviceId,
        channel: ChannelId,
        skdm: ByteArray,
    )

    suspend fun rotateSenderKey(channel: ChannelId): UUID

    suspend fun groupEncrypt(channel: ChannelId, plaintext: ByteArray): ByteArray

    suspend fun groupDecrypt(
        sender: DeviceId,
        channel: ChannelId,
        ciphertext: ByteArray,
    ): ByteArray

    fun encodeTalkStart(decision: FloorDecision, epoch: MediaEpoch): ByteArray

    fun decodeTalkStart(plaintext: ByteArray): Pair<FloorDecision, MediaEpoch>

    suspend fun wrapMediaEpoch(channel: ChannelId, epoch: MediaEpoch): ByteArray

    suspend fun unwrapMediaEpoch(
        sender: DeviceId,
        channel: ChannelId,
        ciphertext: ByteArray,
    ): MediaEpoch

    fun safetyNumber1to1(peer: Aci): String

    /** Account fingerprint changes whenever either account links or revokes a device. */
    fun safetyNumberAccount(
        localDeviceIdentityKeys: List<ByteArray>,
        peer: Aci,
        peerDeviceIdentityKeys: List<ByteArray>,
    ): String

    fun safetyNumberChannel(
        channel: ChannelId,
        memberIdentityKeys: List<ByteArray>,
    ): String

    fun localDevice(): DeviceId

    fun attachTestAuthority(authority: TestCertificateAuthority)

    fun channelSecret(channel: ChannelId): ByteArray
}
