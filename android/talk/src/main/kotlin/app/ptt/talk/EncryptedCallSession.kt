package app.ptt.talk

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.livekit.android.AudioOptions
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.RoomOptions
import io.livekit.android.audio.AudioProcessorInterface
import io.livekit.android.audio.AudioProcessorOptions
import io.livekit.android.audio.NoAudioHandler
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.e2ee.E2EEState
import io.livekit.android.e2ee.KeyProvider
import io.livekit.android.events.RoomEvent
import io.livekit.android.room.Room
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
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
    syntheticCapture: Boolean = false,
    diagnoseRender: Boolean = false,
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
    private val syntheticProcessor = if (BuildConfig.DEBUG && syntheticCapture) {
        SyntheticCallAudioProcessor { playSyntheticSourceMarker() }
    } else {
        null
    }
    private val renderDiagnosticProcessor = if (BuildConfig.DEBUG && diagnoseRender) {
        CallAudioRenderDiagnosticProcessor()
    } else {
        null
    }
    private val room: Room = runCatching {
        val processorOptions = if (syntheticProcessor != null || renderDiagnosticProcessor != null) {
            AudioProcessorOptions(
                capturePostProcessor = syntheticProcessor,
                renderPreProcessor = renderDiagnosticProcessor,
            )
        } else {
            null
        }
        // Core-Telecom owns focus, communication mode, and route selection for the lifetime of
        // this call. LiveKit's default AudioSwitchHandler races Telecom and can silently move an
        // active call back to the earpiece after the user selects Speaker or Bluetooth.
        val overrides = LiveKitOverrides(
            audioOptions = AudioOptions(
                audioHandler = NoAudioHandler(),
                disableCommunicationModeWorkaround = true,
                audioProcessorOptions = processorOptions,
            ),
        )
        LiveKit.create(
            context.applicationContext,
            RoomOptions(e2eeOptions = E2EEOptions(keyProvider, Encryption.Type.GCM)),
            overrides,
        )
    }.getOrElse { error("call-media-room") }
    private val eventScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val trackEncryptionStates = ConcurrentHashMap<String, E2EEState>()
    private val acknowledgedPeers = mutableSetOf<String>()
    private var telecomActive = false
    private var connected = false
    private var resumeMutedAfterRotation = false

    init {
        require(runCatching { java.util.UUID.fromString(callId) }.isSuccess)
        require(epoch > 0 && localParticipantIdentity.isNotBlank())
        runCatching { setRawKey(outboundKey, localParticipantIdentity, epoch) }
            .getOrElse { error("call-media-local-key") }
        eventScope.launch {
            room.events.events.collect { event ->
                if (event is RoomEvent.TrackE2EEStateEvent) {
                    trackEncryptionStates[event.publication.sid] = event.state
                }
            }
        }
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

    /** Connects the ciphertext transport while publication and playback remain muted. */
    suspend fun prepareTransport(serverUrl: String, token: String) {
        check(state == EncryptedCallMediaState.IDLE)
        state = EncryptedCallMediaState.CONNECTING
        try {
            room.connect(serverUrl, token)
            connected = true
            // Transport readiness is not media authorization. Stay securing until every active
            // peer has installed and acknowledged the exact epoch key.
            state = EncryptedCallMediaState.SECURING
        } catch (error: Throwable) {
            state = EncryptedCallMediaState.FAILED
            throw error
        }
    }

    suspend fun completeInitialSecurity(requiredPeerAcis: Set<String>) {
        check(connected && state == EncryptedCallMediaState.SECURING)
        require(acknowledgedPeers.containsAll(requiredPeerAcis.map(String::lowercase))) {
            "Call key acknowledgement is incomplete"
        }
        state = EncryptedCallMediaState.CONNECTED
        if (telecomActive) setMuted(false)
    }

    suspend fun connect(serverUrl: String, token: String, requiredPeerAcis: Set<String>) {
        prepareTransport(serverUrl, token)
        completeInitialSecurity(requiredPeerAcis)
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
        if (muted) syntheticProcessor?.stop() else syntheticProcessor?.start()
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

    fun localAudioTrackCount(): Int = room.localParticipant.audioTrackPublications.size

    fun remoteAudioTrackCount(): Int = room.remoteParticipants.values.sumOf {
        it.audioTrackPublications.size
    }

    fun encryptionStateLabel(): String = trackEncryptionStates.values
        .map(E2EEState::name)
        .distinct()
        .sorted()
        .joinToString("+")
        .ifEmpty { "NO_FRAME_STATE" }

    fun receivedDiagnosticToneBursts(): Int = renderDiagnosticProcessor?.toneBurstCount ?: 0

    fun receivedDiagnosticPeakRms(): Float = renderDiagnosticProcessor?.peakRms ?: 0f

    fun receivedDiagnosticPeakCorrelation(): Float = renderDiagnosticProcessor?.peakCorrelation ?: 0f

    fun captureDiagnosticFormat(): String = syntheticProcessor?.formatLabel() ?: "DISABLED"

    fun renderDiagnosticFormat(): String = renderDiagnosticProcessor?.formatLabel() ?: "DISABLED"

    suspend fun close() {
        runCatching { setMuted(true) }
        releaseNow()
    }

    fun releaseNow() {
        syntheticProcessor?.stop()
        eventScope.cancel()
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

    private fun playSyntheticSourceMarker() {
        thread(name = "ptt-call-acoustic-marker", isDaemon = true) {
            val sampleRate = SyntheticCallAudioProcessor.SAMPLE_RATE
            val markerFrames = (
                sampleRate.toLong() * SyntheticCallAudioProcessor.SOURCE_MARKER_MS / 1_000
            )
                .toInt()
            val samples = ShortArray(markerFrames) { index ->
                (sin(index.toDouble() * 2.0 * Math.PI * 613.0 / sampleRate) * 28_000).toInt().toShort()
            }
            val minimum = AudioTrack.getMinBufferSize(
                sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minimum <= 0) return@thread
            val track = runCatching {
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build(),
                    )
                    .setBufferSizeInBytes(maxOf(minimum, samples.size * 2))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            }.getOrNull() ?: return@thread
            try {
                if (track.state != AudioTrack.STATE_INITIALIZED) return@thread
                if (track.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING) != samples.size) return@thread
                track.play()
                val deadline = System.nanoTime() + 1_000_000_000L
                while (System.nanoTime() < deadline &&
                    track.playbackHeadPosition.toLong().and(0xffff_ffffL) < samples.size
                ) {
                    Thread.sleep(10)
                }
            } finally {
                runCatching { track.stop() }
                track.release()
            }
        }
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

/** Debug-only, non-mutating proof that decrypted fixture samples reached the playback graph. */
internal class CallAudioRenderDiagnosticProcessor : AudioProcessorInterface {
    private var sampleRateHz = SyntheticCallAudioProcessor.SAMPLE_RATE
    private var channelCount = 1
    private var toneActive = false
    @Volatile private var lastNumBands = 0
    @Volatile private var lastNumFrames = 0
    @Volatile private var lastBufferBytes = 0

    @Volatile var toneBurstCount = 0
        private set
    @Volatile var peakRms = 0f
        private set
    @Volatile var peakCorrelation = 0f
        private set

    override fun isEnabled(): Boolean = true

    override fun getName(): String = "PTT call render diagnostic"

    @Synchronized
    override fun initializeAudioProcessing(sampleRateHz: Int, numChannels: Int) {
        require(sampleRateHz > 0 && numChannels > 0)
        this.sampleRateHz = sampleRateHz
        channelCount = numChannels
        toneActive = false
        toneBurstCount = 0
        peakRms = 0f
        peakCorrelation = 0f
    }

    @Synchronized
    override fun resetAudioProcessing(newRate: Int) {
        require(newRate > 0)
        sampleRateHz = newRate
        toneActive = false
    }

    @Synchronized
    override fun processAudio(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        require(numBands > 0 && numFrames > 0)
        lastNumBands = numBands
        lastNumFrames = numFrames
        lastBufferBytes = buffer.remaining()
        val samples = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
        val channelsInBuffer = if (samples.remaining() >= numFrames * channelCount) channelCount else 1
        val frames = minOf(numFrames, samples.remaining() / channelsInBuffer)
        if (frames == 0) return
        val analysisRate = sampleRateHz
        var sumSquares = 0.0
        var real = 0.0
        var imaginary = 0.0
        for (frame in 0 until frames) {
            val value = samples.get(frame * channelsInBuffer).toDouble()
            val phase = frame.toDouble() * 2.0 * Math.PI * SyntheticCallAudioProcessor.TONE_HZ / analysisRate
            sumSquares += value * value
            real += value * cos(phase)
            imaginary -= value * sin(phase)
        }
        val rms = sqrt(sumSquares / frames).toFloat()
        peakRms = maxOf(peakRms, rms)
        val correlation = if (rms > 0f) {
            sqrt(real * real + imaginary * imaginary) / (frames * rms)
        } else {
            0.0
        }
        peakCorrelation = maxOf(peakCorrelation, correlation.toFloat())
        val detected = rms >= MINIMUM_RMS && correlation >= MINIMUM_CORRELATION
        if (detected && !toneActive) toneBurstCount += 1
        toneActive = detected
    }

    fun formatLabel(): String =
        "${sampleRateHz}hz-${channelCount}ch-${lastNumBands}bands-${lastNumFrames}frames-${lastBufferBytes}bytes"

    private companion object {
        const val MINIMUM_RMS = 300f
        const val MINIMUM_CORRELATION = 0.55
    }
}

/** Debug acoustic fixture. Product builds cannot enable this processor. */
internal class SyntheticCallAudioProcessor(
    private val sourceMarker: () -> Unit = {},
) : AudioProcessorInterface {
    @Volatile private var active = false
    private var sampleRateHz = SAMPLE_RATE
    private var channelCount = 1
    private var sampleFrame = 0L
    private var lastMarkerCycle = -1L
    @Volatile private var lastNumBands = 0
    @Volatile private var lastNumFrames = 0
    @Volatile private var lastBufferBytes = 0

    override fun isEnabled(): Boolean = true

    override fun getName(): String = "PTT call acoustic fixture"

    @Synchronized
    fun start() {
        sampleFrame = 0
        lastMarkerCycle = -1
        active = true
    }

    fun stop() {
        active = false
    }

    @Synchronized
    override fun initializeAudioProcessing(sampleRateHz: Int, numChannels: Int) {
        require(sampleRateHz > 0 && numChannels > 0)
        this.sampleRateHz = sampleRateHz
        channelCount = numChannels
        sampleFrame = 0
        lastMarkerCycle = -1
    }

    @Synchronized
    override fun resetAudioProcessing(newRate: Int) {
        require(newRate > 0)
        sampleRateHz = newRate
        sampleFrame = 0
        lastMarkerCycle = -1
    }

    @Synchronized
    override fun processAudio(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        require(numBands > 0 && numFrames > 0)
        lastNumBands = numBands
        lastNumFrames = numFrames
        lastBufferBytes = buffer.remaining()
        // WebRTC's external APM hook supplies native-endian 32-bit float samples in full-band time
        // order. numBands reports the APM's internal analysis bands; it does not partition this
        // Java buffer. Values use PCM scale (roughly signed-16-bit range), not normalized ±1.
        val samples = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer()
        val channelsInBuffer = if (samples.remaining() >= numFrames * channelCount) {
            channelCount
        } else {
            1
        }
        val frames = minOf(numFrames, samples.remaining() / channelsInBuffer)
        val fixtureRate = sampleRateHz
        val cycleFrames = fixtureRate.toLong() * CYCLE_MS / 1_000
        val markerFrames = fixtureRate.toLong() * MARKER_MS / 1_000
        val toneEndFrames = markerFrames + fixtureRate.toLong() * TONE_MS / 1_000
        for (frameIndex in 0 until frames) {
            val absoluteFrame = sampleFrame + frameIndex
            val cycle = absoluteFrame / cycleFrames
            val position = absoluteFrame % cycleFrames
            if (active && cycle < BURSTS && position < markerFrames && cycle != lastMarkerCycle) {
                lastMarkerCycle = cycle
                sourceMarker()
            }
            val value = if (active && cycle < BURSTS && position in markerFrames until toneEndFrames) {
                val toneFrame = position - markerFrames
                (sin(toneFrame.toDouble() * 2.0 * Math.PI * TONE_HZ / fixtureRate) * 22_000.0).toFloat()
            } else {
                0f
            }
            for (channel in 0 until channelsInBuffer) {
                samples.put(frameIndex * channelsInBuffer + channel, value)
            }
        }
        val populatedSamples = frames * channelsInBuffer
        for (sampleIndex in populatedSamples until samples.remaining()) samples.put(sampleIndex, 0f)
        sampleFrame += frames
    }

    fun formatLabel(): String =
        "${sampleRateHz}hz-${channelCount}ch-${lastNumBands}bands-${lastNumFrames}frames-${lastBufferBytes}bytes"

    internal companion object {
        const val SAMPLE_RATE = 48_000
        const val BURSTS = 5L
        // Media starts 200 ms after the source timestamp. The audible local marker continues for
        // 400 ms so a fixed room microphone can establish that timestamp even when the device is
        // partly shadowed; the two narrow frequencies remain independently measurable while they
        // overlap.
        const val MARKER_MS = 200L
        const val SOURCE_MARKER_MS = 400L
        const val TONE_MS = 1_000L
        const val CYCLE_MS = 1_800L
        const val TONE_HZ = 997.0
    }
}
