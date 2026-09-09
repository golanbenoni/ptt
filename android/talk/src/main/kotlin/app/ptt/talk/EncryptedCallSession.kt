package app.ptt.talk

import android.content.Context
import io.livekit.android.LiveKit
import io.livekit.android.RoomOptions
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.e2ee.KeyProvider
import io.livekit.android.room.Room
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import livekit.LivekitModels.Encryption
import livekit.org.webrtc.FrameCryptorFactory
import livekit.org.webrtc.FrameCryptorKeyDerivationAlgorithm
import livekit.org.webrtc.FrameCryptorKeyProvider

internal enum class EncryptedCallMediaState { IDLE, SECURING, CONNECTING, CONNECTED, ENDED, FAILED }

/**
 * One fail-closed LiveKit room. Core-Telecom owns the platform route; this class only publishes
 * after every active peer has acknowledged the device's Double-Ratchet-delivered outbound key.
 */
internal class EncryptedCallSession(
    context: Context,
    val callId: String,
    var epoch: Int,
    val localParticipantIdentity: String,
) {
    var outboundKey = randomKey()
        private set
    var state = EncryptedCallMediaState.IDLE
        private set
    var isMuted = true
        private set

    @Suppress("unused")
    private val liveKitInitialized = runCatching { LiveKit.init(context.applicationContext) }
        .getOrElse { error("call-media-runtime") }
    private val keyProvider = runCatching { BinaryKeyProvider() }
        .getOrElse { error("call-media-key-provider") }
    private val room: Room = runCatching {
        LiveKit.create(
            context.applicationContext,
            RoomOptions(e2eeOptions = E2EEOptions(keyProvider, Encryption.Type.GCM)),
        )
    }.getOrElse { error("call-media-room") }
    private val acknowledgedPeers = mutableSetOf<String>()
    private var telecomActive = false
    private var connected = false
    private var resumeMutedAfterRotation = false

    init {
        require(runCatching { java.util.UUID.fromString(callId) }.isSuccess)
        require(epoch > 0 && localParticipantIdentity.isNotBlank())
        runCatching { setRawKey(outboundKey, localParticipantIdentity, epoch) }
            .getOrElse { error("call-media-local-key") }
    }

    fun installParticipantKey(key: ByteArray, participantIdentity: String, announcedEpoch: Int) {
        require(key.size == 32 && participantIdentity.isNotBlank())
        require(announcedEpoch == epoch) { "Stale call epoch" }
        setRawKey(key, participantIdentity, announcedEpoch)
    }

    fun acknowledgePeer(peerAci: String, acknowledgedEpoch: Int) {
        require(acknowledgedEpoch == epoch) { "Stale call epoch" }
        acknowledgedPeers += peerAci.lowercase()
    }

    suspend fun connect(serverUrl: String, token: String, requiredPeerAcis: Set<String>) {
        check(state == EncryptedCallMediaState.IDLE || state == EncryptedCallMediaState.SECURING)
        state = EncryptedCallMediaState.SECURING
        require(acknowledgedPeers.containsAll(requiredPeerAcis.map(String::lowercase))) {
            "Call key acknowledgement is incomplete"
        }
        state = EncryptedCallMediaState.CONNECTING
        try {
            room.connect(serverUrl, token)
            connected = true
            state = EncryptedCallMediaState.CONNECTED
            if (telecomActive) setMuted(false)
        } catch (error: Throwable) {
            state = EncryptedCallMediaState.FAILED
            throw error
        }
    }

    suspend fun rotateTo(newEpoch: Int) {
        require(newEpoch > epoch) { "Call epochs may only advance" }
        resumeMutedAfterRotation = isMuted
        if (connected) room.localParticipant.setMicrophoneEnabled(false)
        isMuted = true
        state = EncryptedCallMediaState.SECURING
        epoch = newEpoch
        outboundKey = randomKey()
        acknowledgedPeers.clear()
        setRawKey(outboundKey, localParticipantIdentity, newEpoch)
    }

    suspend fun completeRotation(requiredPeerAcis: Set<String>) {
        require(connected) { "Call has not connected" }
        require(acknowledgedPeers.containsAll(requiredPeerAcis.map(String::lowercase))) {
            "Call key acknowledgement is incomplete"
        }
        state = EncryptedCallMediaState.CONNECTED
        if (telecomActive) setMuted(resumeMutedAfterRotation)
    }

    suspend fun setTelecomActive(active: Boolean) {
        telecomActive = active
        if (state == EncryptedCallMediaState.CONNECTED) setMuted(!active)
    }

    suspend fun setMuted(muted: Boolean) {
        if (state != EncryptedCallMediaState.CONNECTED && !muted) return
        room.localParticipant.setMicrophoneEnabled(!muted)
        isMuted = muted
    }

    fun activeSpeakerIdentities(): Set<String> = room.activeSpeakers
        .mapNotNull { it.identity?.value }
        .toSet()

    fun connectionQualityLabel(): String = when (room.localParticipant.connectionQuality.name) {
        "EXCELLENT" -> "Excellent"
        "GOOD" -> "Good"
        "POOR" -> "Poor"
        "LOST" -> "Reconnecting"
        else -> "Checking"
    }

    suspend fun close() {
        runCatching { setMuted(true) }
        releaseNow()
    }

    fun releaseNow() {
        room.release()
        connected = false
        telecomActive = false
        acknowledgedPeers.clear()
        state = EncryptedCallMediaState.ENDED
    }

    private fun setRawKey(material: ByteArray, participantIdentity: String, keyEpoch: Int) {
        val key = frameKey(material, callId, keyEpoch, participantIdentity)
        keyProvider.setBinaryKey(key, participantIdentity, keyEpoch % 16)
    }

    /**
     * LiveKit Android 2.28.2's stock provider exposes participant keys as String and therefore
     * UTF-8 transforms arbitrary key material. This provider keeps the SDK's required latest-index
     * bookkeeping while passing exact bytes to WebRTC, matching LiveKit Swift's Data API.
     * FrameCryptorKeyProvider.setKey's Boolean is deliberately not used as a readiness signal;
     * LiveKit's own provider also treats key installation as asynchronous state setup.
     */
    private class BinaryKeyProvider : KeyProvider {
        private val latestSetIndex = mutableMapOf<String, Int>()
        override var enableSharedKey = false
        override val rtcKeyProvider: FrameCryptorKeyProvider =
            FrameCryptorFactory.createFrameCryptorKeyProvider(
                false,
                "LKFrameEncryptionKey".toByteArray(StandardCharsets.UTF_8),
                16,
                "LK-ROCKS".toByteArray(StandardCharsets.UTF_8),
                -1,
                16,
                true,
                FrameCryptorKeyDerivationAlgorithm.HKDF,
            )

        fun setBinaryKey(key: ByteArray, participantId: String, keyIndex: Int) {
            latestSetIndex[participantId] = keyIndex
            rtcKeyProvider.setKey(participantId, keyIndex, key)
        }

        override fun setSharedKey(key: String, keyIndex: Int?): Boolean =
            rtcKeyProvider.setSharedKey(keyIndex ?: 0, key.toByteArray(StandardCharsets.UTF_8))

        override fun ratchetSharedKey(keyIndex: Int?): ByteArray =
            rtcKeyProvider.ratchetSharedKey(keyIndex ?: 0)

        override fun exportSharedKey(keyIndex: Int?): ByteArray =
            rtcKeyProvider.exportSharedKey(keyIndex ?: 0)

        override fun setKey(key: String, participantId: String?, keyIndex: Int?) {
            if (participantId != null) {
                setBinaryKey(key.toByteArray(StandardCharsets.UTF_8), participantId, keyIndex ?: 0)
            }
        }

        override fun ratchetKey(participantId: String, keyIndex: Int?): ByteArray =
            rtcKeyProvider.ratchetKey(participantId, keyIndex ?: 0)

        override fun exportKey(participantId: String, keyIndex: Int?): ByteArray =
            rtcKeyProvider.exportKey(participantId, keyIndex ?: 0)

        override fun setSifTrailer(trailer: ByteArray) = rtcKeyProvider.setSifTrailer(trailer)

        override fun getLatestKeyIndex(participantId: String): Int = latestSetIndex[participantId] ?: 0
    }

    companion object {
        private fun randomKey() = ByteArray(32).also(SecureRandom()::nextBytes)

        internal fun frameKey(
            material: ByteArray,
            callId: String,
            epoch: Int,
            participantIdentity: String,
        ): ByteArray = hkdfSha256(
            material,
            callId.toByteArray(StandardCharsets.UTF_8),
            "ptt-talk-call-v1|$epoch|$participantIdentity".toByteArray(StandardCharsets.UTF_8),
            32,
        )

        private fun hkdfSha256(input: ByteArray, salt: ByteArray, info: ByteArray, size: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = mac.doFinal(input)
            val output = ByteBuffer.allocate(size)
            var previous = ByteArray(0)
            var counter = 1
            while (output.hasRemaining()) {
                mac.init(SecretKeySpec(prk, "HmacSHA256"))
                mac.update(previous)
                mac.update(info)
                mac.update(counter.toByte())
                previous = mac.doFinal()
                output.put(previous, 0, minOf(output.remaining(), previous.size))
                counter += 1
            }
            return output.array()
        }
    }
}
