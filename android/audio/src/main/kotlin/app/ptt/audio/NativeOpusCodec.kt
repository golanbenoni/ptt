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
