package app.ptt.talk

import app.ptt.audio.AndroidAudioEngine
import app.ptt.audio.JitterPlayout
import app.ptt.audio.NativeAdaptiveJitterBuffer
import app.ptt.audio.NativeOpusDecoder
import app.ptt.audio.NativeOpusEncoder
import app.ptt.audio.VOICE_SAMPLES_PER_FRAME
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import app.ptt.media.MediaRelay
import app.ptt.media.MEDIA_FLAG_END
import app.ptt.media.MEDIA_FLAG_HMAC8
import app.ptt.media.MEDIA_FLAG_START
import app.ptt.media.ProductionMediaDatagram
import app.ptt.media.ProductionMediaHeader
import app.ptt.media.ProductionVoicePayload
import app.ptt.media.SFrameCounterStore
import app.ptt.media.SFrameDecryptor
import app.ptt.media.SFrameEncryptor
import app.ptt.media.productionSFrameAad
import app.ptt.media.talkIdPrefix
import android.util.Log
import java.io.Closeable
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

internal class SqlCipherSFrameCounterStore(
    private val store: EncryptedSignalProtocolStore,
    private val streamPrefix: String,
) : SFrameCounterStore {
    override fun takeNext(kid: ULong): ULong =
        store.nextMediaCounter("$streamPrefix/${kid.toString(16)}").toULong()
}

internal class OutgoingVoiceStream(
    private val audio: AndroidAudioEngine,
    private val relay: MediaRelay,
    private val demuxToken: ByteArray,
    private val announcement: MediaEpochAnnouncement,
    counterStore: SFrameCounterStore,
    private val onPacketSent: (ByteArray) -> Unit = {},
    private val onMediaStarted: () -> Unit = {},
    private val onError: (Throwable) -> Unit,
) : Closeable {
    private val encoder = NativeOpusEncoder()
    private val encryptor = SFrameEncryptor(announcement.kid, announcement.baseKey, counterStore)
    private val aad =
        productionSFrameAad(
            announcement.channelId,
            announcement.talkId,
            announcement.senderDemux,
        )
    private var sequence = SecureRandom().nextInt().toLong() and 0xffff_ffffL
    private var timestamp = SecureRandom().nextInt().toLong() and 0xffff_ffffL
    private var first = true
    private val failureReported = AtomicBoolean(false)
    @Volatile private var closed = false

    fun start() {
        audio.startCapture { pcm, _ ->
            if (!closed && !failureReported.get()) {
                runCatching { sendPcm(pcm, if (first) MEDIA_FLAG_START else 0) }
                    .onFailure { error ->
                        if (failureReported.compareAndSet(false, true)) onError(error)
                    }
            }
        }
    }

    @Synchronized
    private fun sendPcm(pcm: ShortArray, extraFlags: Int) {
        // Capture can observe `closed == false` immediately before close() acquires this
        // monitor. Once it gets the monitor the encoder is already closed, so discard that
        // stale callback instead of surfacing a spurious transmission error.
        if (closed) return
        val opus = encoder.encode(pcm)
        val sframe = encryptor.encrypt(aad, ProductionVoicePayload.pack(opus))
        val packet =
            ProductionMediaDatagram.encode(
                ProductionMediaHeader(
                    extraFlags or MEDIA_FLAG_HMAC8,
                    announcement.senderDemux,
                    sequence,
                    timestamp,
                    talkIdPrefix(announcement.talkId),
                ),
                sframe,
                demuxToken,
            )
        relay.send(packet)
        onPacketSent(packet.copyOf())
        if (first && extraFlags and MEDIA_FLAG_END == 0) {
            onMediaStarted()
            if (BuildConfig.DEBUG) Log.i("PTT_MEDIA", "TX_START encrypted")
        }
        first = false
        sequence = (sequence + 1) and 0xffff_ffffL
        timestamp = (timestamp + VOICE_SAMPLES_PER_FRAME) and 0xffff_ffffL
    }

    override fun close() {
        var endError: Throwable? = null
        synchronized(this) {
            if (closed) return
            if (!failureReported.get()) {
                endError = runCatching {
                    sendPcm(ShortArray(VOICE_SAMPLES_PER_FRAME), MEDIA_FLAG_END)
                    if (BuildConfig.DEBUG) Log.i("PTT_MEDIA", "TX_END encrypted")
                }.exceptionOrNull()
            }
            closed = true
            encoder.close()
        }
        audio.stopCapture()
        endError?.let { error ->
            if (failureReported.compareAndSet(false, true)) onError(error)
        }
    }
}

internal class IncomingVoiceStream(
    private val audio: AndroidAudioEngine,
    val senderAci: String,
    val senderDeviceId: Int,
    val announcement: MediaEpochAnnouncement,
    private val onError: (Throwable) -> Unit = {},
    private val onStarted: () -> Unit = {},
    private val onEnded: (IncomingVoiceStats) -> Unit = {},
) : Closeable {
    private data class PendingPacket(
        val sequence: Long,
        val sentTimestampMs: Long,
        val arrivalMs: Long,
        val bytes: ByteArray,
        val end: Boolean,
    )

    private val decoder = NativeOpusDecoder()
    private val jitter = NativeAdaptiveJitterBuffer()
    private val decryptor = SFrameDecryptor().apply { addKey(announcement.kid, announcement.baseKey) }
    private val aad =
        productionSFrameAad(
            announcement.channelId,
            announcement.talkId,
            announcement.senderDemux,
        )
    private var first = true
    private var firstPacketAccepted = false
    private val authenticatedPackets = AtomicInteger()
    private val authenticatedEnd = AtomicBoolean(false)
    private val playedPackets = AtomicInteger()
    private val concealedFrames = AtomicInteger()
    private var highestTimestamp: Long? = null
    private var lastPacketArrivalMs: Long? = null
    @Volatile private var closed = false
    private val started = AtomicBoolean(false)
    private val pendingLock = Any()
    private val pendingBeforeStart = mutableListOf<PendingPacket>()
    @Volatile private var playoutThread: Thread? = null

    fun start() {
        if (!started.compareAndSet(false, true)) return
        synchronized(pendingLock) {
            pendingBeforeStart
                .sortedBy { it.sentTimestampMs }
                .forEach { packet -> pushToJitter(packet) }
            pendingBeforeStart.clear()
        }
        playoutThread =
            thread(start = true, name = "ptt-jitter-playout", priority = Thread.NORM_PRIORITY + 1) {
                while (!closed && !Thread.currentThread().isInterrupted) {
                    val started = System.nanoTime()
                    runCatching { playoutOne() }.onFailure(onError)
                    val elapsedMs = (System.nanoTime() - started) / 1_000_000
                    if (elapsedMs < 20) {
                        try {
                            Thread.sleep(20 - elapsedMs)
                        } catch (_: InterruptedException) {
                            break
                        }
                    }
                }
            }
    }

    val isSos: Boolean
        get() = announcement.isSos

    val hasAuthenticatedPackets: Boolean
        get() = authenticatedPackets.get() > 0

    val hasAuthenticatedEnd: Boolean
        get() = authenticatedEnd.get()

    fun matches(packet: ByteArray): Boolean {
        val received = runCatching { ProductionMediaDatagram.decode(packet) }.getOrNull() ?: return false
        return received.header.senderDemux == announcement.senderDemux &&
            received.header.talkIdPrefix.contentEquals(talkIdPrefix(announcement.talkId))
    }

    fun accept(packet: ByteArray): Boolean {
        val received = ProductionMediaDatagram.decode(packet)
        if (received.header.senderDemux != announcement.senderDemux ||
            !received.header.talkIdPrefix.contentEquals(talkIdPrefix(announcement.talkId))
        ) return false
        val opus = ProductionVoicePayload.unpack(decryptor.decrypt(aad, received.sframe))
        authenticatedPackets.incrementAndGet()
        val buffered = byteArrayOf(received.header.flags.toByte()) + opus
        val extendedTimestamp = extendTimestamp(received.header.timestampRtp)
        val pending =
            PendingPacket(
                sequence = received.header.sequence,
                sentTimestampMs = extendedTimestamp * 1_000 / 48_000,
                arrivalMs = System.nanoTime() / 1_000_000,
                bytes = buffered,
                end = received.header.flags and MEDIA_FLAG_END != 0,
            )
        if (BuildConfig.DEBUG) {
            val count = authenticatedPackets.get()
            val gapMs = lastPacketArrivalMs?.let { pending.arrivalMs - it }
            if (count <= 3 || (gapMs != null && gapMs >= 100)) {
                Log.i(
                    "PTT_MEDIA",
                    "RX_PACKET_TIMING count=$count gap_ms=${gapMs ?: 0} " +
                        "playout_started=${started.get()}",
                )
            }
            lastPacketArrivalMs = pending.arrivalMs
        }
        if (pending.end) authenticatedEnd.set(true)
        synchronized(pendingLock) {
            if (started.get()) {
                pushToJitter(pending)
            } else {
                pendingBeforeStart += pending
            }
        }
        if (!firstPacketAccepted) {
            firstPacketAccepted = true
            if (BuildConfig.DEBUG) Log.i("PTT_MEDIA", "RX_PACKET_AUTHENTICATED")
        }
        return true
    }

    private fun pushToJitter(packet: PendingPacket) {
        jitter.push(
            packet.sequence,
            packet.sentTimestampMs,
            packet.arrivalMs,
            packet.bytes,
        )
        if (packet.end) jitter.flush()
    }

    private fun playoutOne() {
        when (val next = jitter.pop()) {
            JitterPlayout.Buffering -> Unit
            JitterPlayout.Missing -> {
                concealedFrames.incrementAndGet()
                audio.play(decoder.decode(null))
            }
            is JitterPlayout.Packet -> {
                require(next.bytes.size > 1) { "jitter packet is truncated" }
                val flags = next.bytes[0].toInt() and 0xff
                val playbackTarget = audio.play(decoder.decode(next.bytes.copyOfRange(1, next.bytes.size)))
                playedPackets.incrementAndGet()
                if (first) {
                    first = false
                    onStarted()
                    if (BuildConfig.DEBUG) {
                        Log.i("PTT_MEDIA", "RX_START authenticated-decrypted-jittered")
                    }
                }
                if (flags and MEDIA_FLAG_END != 0) {
                    check(audio.awaitPlayback(playbackTarget)) {
                        "authenticated audio did not advance through the physical playback route"
                    }
                    onEnded(
                        IncomingVoiceStats(
                            authenticatedPackets = authenticatedPackets.get(),
                            playedPackets = playedPackets.get(),
                            concealedFrames = concealedFrames.get(),
                        ),
                    )
                    closed = true
                }
            }
        }
    }

    @Synchronized
    private fun extendTimestamp(timestamp: Long): Long {
        val highest = highestTimestamp
        if (highest == null) {
            highestTimestamp = timestamp
            return timestamp
        }
        val base = highest and 0xffff_ffffL.inv()
        val candidate = base or timestamp
        val extended =
            when {
                candidate + (1L shl 31) < highest -> candidate + (1L shl 32)
                candidate > highest + (1L shl 31) -> candidate - (1L shl 32)
                else -> candidate
            }
        if (extended > highest) highestTimestamp = extended
        return extended
    }

    override fun close() {
        val worker = playoutThread
        if (closed && Thread.currentThread() === worker) return
        closed = true
        worker?.interrupt()
        if (worker != null && Thread.currentThread() !== worker) worker.join(1_000)
        synchronized(pendingLock) { pendingBeforeStart.clear() }
        jitter.close()
        decoder.close()
    }
}

internal data class IncomingVoiceStats(
    val authenticatedPackets: Int,
    val playedPackets: Int,
    val concealedFrames: Int,
)

internal enum class PttCallAudioDecision {
    PLAY,
    ARCHIVE_ONLY,
    PREEMPT_CALL,
}

/** The normal-call audio route is exclusive; only priority SOS may take it away. */
internal object PttCallAudioPriorityPolicy {
    fun decide(callActive: Boolean, isSos: Boolean): PttCallAudioDecision = when {
        !callActive -> PttCallAudioDecision.PLAY
        isSos -> PttCallAudioDecision.PREEMPT_CALL
        else -> PttCallAudioDecision.ARCHIVE_ONLY
    }
}
