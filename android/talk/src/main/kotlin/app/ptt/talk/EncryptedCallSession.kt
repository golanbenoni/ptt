package app.ptt.talk

import android.content.Context
import io.livekit.android.LiveKit
import io.livekit.android.RoomOptions
import io.livekit.android.e2ee.BaseKeyProvider
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.room.Room
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import livekit.LivekitModels.Encryption
import livekit.org.webrtc.FrameCryptorKeyDerivationAlgorithm

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

    private val keyProvider = BaseKeyProvider(
        enableSharedKey = false,
        discardFrameWhenCryptorNotReady = true,
        keyDerivationAlgorithm = FrameCryptorKeyDerivationAlgorithm.HKDF,
    )
    private val room: Room = LiveKit.create(
        context.applicationContext,
        RoomOptions(e2eeOptions = E2EEOptions(keyProvider, Encryption.Type.GCM)),
    )
    private val acknowledgedPeers = mutableSetOf<String>()
    private var telecomActive = false
    private var connected = false
    private var resumeMutedAfterRotation = false

    init {
        require(runCatching { java.util.UUID.fromString(callId) }.isSuccess)
        require(epoch > 0 && localParticipantIdentity.isNotBlank())
        setRawKey(outboundKey, localParticipantIdentity, epoch)
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
        // LiveKit 2.28.2's public String overload applies UTF-8 conversion. The exposed WebRTC
        // provider accepts exact binary bytes and is required for Swift/Android interoperability.
        check(keyProvider.rtcKeyProvider.setKey(participantIdentity, keyEpoch % 16, key))
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
