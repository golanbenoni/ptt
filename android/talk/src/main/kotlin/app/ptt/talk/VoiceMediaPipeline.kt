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
    @Volatile private var closed = false

    fun start() {
        audio.startCapture { pcm, _ ->
            if (!closed) {
                runCatching { sendPcm(pcm, if (first) MEDIA_FLAG_START else 0) }
                    .onFailure(onError)
            }
        }
    }

    @Synchronized
    private fun sendPcm(pcm: ShortArray, extraFlags: Int) {
        check(!closed)
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
        if (first && BuildConfig.DEBUG) Log.i("PTT_MEDIA", "TX_START encrypted")
        first = false
        sequence = (sequence + 1) and 0xffff_ffffL
        timestamp = (timestamp + VOICE_SAMPLES_PER_FRAME) and 0xffff_ffffL
    }

    override fun close() {
        synchronized(this) {
            if (closed) return
            runCatching { sendPcm(ShortArray(VOICE_SAMPLES_PER_FRAME), MEDIA_FLAG_END) }
            closed = true
            encoder.close()
        }
        audio.stopCapture()
    }
}

internal class IncomingVoiceStream(
    private val audio: AndroidAudioEngine,
    val senderAci: String,
    val senderDeviceId: Int,
    val announcement: MediaEpochAnnouncement,
    private val onError: (Throwable) -> Unit = {},
    private val onEnded: () -> Unit = {},
) : Closeable {
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
    private var highestTimestamp: Long? = null
    @Volatile private var closed = false
    private val playoutThread =
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
        val buffered = byteArrayOf(received.header.flags.toByte()) + opus
        val extendedTimestamp = extendTimestamp(received.header.timestampRtp)
        jitter.push(
            received.header.sequence,
            extendedTimestamp * 1_000 / 48_000,
            System.nanoTime() / 1_000_000,
            buffered,
        )
        if (received.header.flags and MEDIA_FLAG_END != 0) jitter.flush()
        return true
    }

    private fun playoutOne() {
        when (val next = jitter.pop()) {
            JitterPlayout.Buffering -> Unit
            JitterPlayout.Missing -> audio.play(decoder.decode(null))
            is JitterPlayout.Packet -> {
                require(next.bytes.size > 1) { "jitter packet is truncated" }
                val flags = next.bytes[0].toInt() and 0xff
                audio.play(decoder.decode(next.bytes.copyOfRange(1, next.bytes.size)))
                if (first && BuildConfig.DEBUG) {
                    first = false
                    Log.i("PTT_MEDIA", "RX_START authenticated-decrypted-jittered")
                }
                if (flags and MEDIA_FLAG_END != 0) {
                    onEnded()
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
        if (closed && Thread.currentThread() === playoutThread) return
        closed = true
        playoutThread.interrupt()
        if (Thread.currentThread() !== playoutThread) playoutThread.join(1_000)
        jitter.close()
        decoder.close()
    }
}
