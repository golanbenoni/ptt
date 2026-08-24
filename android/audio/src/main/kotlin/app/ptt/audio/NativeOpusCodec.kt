package app.ptt.audio

import java.io.Closeable

/** Rust/libopus encoder available on every supported Android API level. */
class NativeOpusEncoder : Closeable {
    private var handle = NativeOpusBridge.encoderCreate().also { check(it != 0L) }

    @Synchronized
    fun encode(pcm: ShortArray): ByteArray {
        check(handle != 0L) { "encoder is closed" }
        require(pcm.size == VOICE_SAMPLES_PER_FRAME) { "encoding requires one 20 ms frame" }
        return NativeOpusBridge.encoderEncode(handle, pcm)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) NativeOpusBridge.encoderDestroy(handle)
        handle = 0L
    }
}

/** Rust/libopus decoder with packet-loss concealment for missing frames. */
class NativeOpusDecoder : Closeable {
    private var handle = NativeOpusBridge.decoderCreate().also { check(it != 0L) }

    @Synchronized
    fun decode(packet: ByteArray?): ShortArray {
        check(handle != 0L) { "decoder is closed" }
        packet?.let { require(it.isNotEmpty()) { "Opus packet is empty" } }
        return NativeOpusBridge.decoderDecode(handle, packet ?: ByteArray(0), packet == null)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) NativeOpusBridge.decoderDestroy(handle)
        handle = 0L
    }
}

sealed interface JitterPlayout {
    data object Buffering : JitterPlayout
    data object Missing : JitterPlayout
    data class Packet(val bytes: ByteArray) : JitterPlayout
}

/** Rust adaptive reorder/jitter buffer used by the actual playback path. */
class NativeAdaptiveJitterBuffer : Closeable {
    private var handle = NativeJitterBridge.create().also { check(it != 0L) }

    @Synchronized
    fun push(
        sequence: Long,
        sentTimestampMs: Long,
        arrivalMs: Long,
        packet: ByteArray,
    ) {
        check(handle != 0L) { "jitter buffer is closed" }
        require(sequence in 0..0xffff_ffffL && sentTimestampMs >= 0 && arrivalMs >= 0 && packet.isNotEmpty())
        NativeJitterBridge.push(handle, sequence, sentTimestampMs, arrivalMs, packet)
    }

    @Synchronized
    fun pop(): JitterPlayout {
        check(handle != 0L) { "jitter buffer is closed" }
        val packet = NativeJitterBridge.pop(handle) ?: return JitterPlayout.Buffering
        return if (packet.isEmpty()) JitterPlayout.Missing else JitterPlayout.Packet(packet)
    }

    @Synchronized
    fun targetDelayMs(): Long {
        check(handle != 0L) { "jitter buffer is closed" }
        return NativeJitterBridge.targetDelayMs(handle)
    }

    @Synchronized
    fun flush() {
        check(handle != 0L) { "jitter buffer is closed" }
        NativeJitterBridge.flush(handle)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) NativeJitterBridge.destroy(handle)
        handle = 0L
    }
}

internal object NativeOpusBridge {
    init {
        System.loadLibrary("ptt_media")
    }

    external fun encoderCreate(): Long
    external fun encoderEncode(handle: Long, pcm: ShortArray): ByteArray
    external fun encoderDestroy(handle: Long)
    external fun decoderCreate(): Long
    external fun decoderDecode(handle: Long, packet: ByteArray, missing: Boolean): ShortArray
    external fun decoderDestroy(handle: Long)
}

internal object NativeJitterBridge {
    init {
        System.loadLibrary("ptt_media")
    }

    external fun create(): Long
    external fun push(
        handle: Long,
        sequence: Long,
        sentTimestampMs: Long,
        arrivalMs: Long,
        packet: ByteArray,
    )
    external fun pop(handle: Long): ByteArray?
    external fun targetDelayMs(handle: Long): Long
    external fun flush(handle: Long)
    external fun destroy(handle: Long)
}
