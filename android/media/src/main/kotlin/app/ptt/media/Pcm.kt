package app.ptt.media

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

const val SAMPLE_RATE = 16_000
const val FRAME_MS = 20
const val SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_MS / 1000
const val FRAME_BYTES = SAMPLES_PER_FRAME * 2

fun sineFrame(index: Int, freqHz: Double = 440.0): ByteArray {
    val start = index * SAMPLES_PER_FRAME
    val buf = ByteBuffer.allocate(FRAME_BYTES).order(ByteOrder.LITTLE_ENDIAN)
    for (n in 0 until SAMPLES_PER_FRAME) {
        val t = (start + n).toDouble() / SAMPLE_RATE
        val s = (sin(2.0 * PI * freqHz * t) * 16_000).toInt().toShort()
        buf.putShort(s)
    }
    return buf.array()
}

fun writeWav(pcm: ByteArray, file: File) {
    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
    header.put("RIFF".toByteArray())
    header.putInt(36 + pcm.size)
    header.put("WAVE".toByteArray())
    header.put("fmt ".toByteArray())
    header.putInt(16)
    header.putShort(1)
    header.putShort(1)
    header.putInt(SAMPLE_RATE)
    header.putInt(SAMPLE_RATE * 2)
    header.putShort(2)
    header.putShort(16)
    header.put("data".toByteArray())
    header.putInt(pcm.size)
    file.parentFile?.mkdirs()
    file.outputStream().use {
        it.write(header.array())
        it.write(pcm)
    }
}

fun pcmEnergy(pcm: ByteArray): Long {
    var energy = 0L
    var i = 0
    while (i + 1 < pcm.size) {
        val s = (pcm[i].toInt() and 0xff) or (pcm[i + 1].toInt() shl 8)
        energy += kotlin.math.abs(s.toShort().toInt())
        i += 2
    }
    return energy
}
