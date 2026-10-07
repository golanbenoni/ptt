package app.ptt.talk

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build

/** Decodes encrypted staging bytes in memory, without a plaintext temporary video. */
internal object ChatVideoPreview {
    fun image(bytes: ByteArray): Bitmap? = runCatching {
        val source = object : MediaDataSource() {
            override fun getSize() = bytes.size.toLong()
            override fun close() = Unit
            override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
                if (position < 0 || position >= bytes.size) return -1
                val count = minOf(size, bytes.size - position.toInt())
                bytes.copyInto(buffer, offset, position.toInt(), position.toInt() + count)
                return count
            }
        }
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(source)
            if (Build.VERSION.SDK_INT >= 27) {
                retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 480)
            } else {
                val original = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                original?.let {
                    val scale = minOf(1f, 480f / maxOf(it.width, it.height))
                    if (scale == 1f) it else Bitmap.createScaledBitmap(it, maxOf(1, (it.width * scale).toInt()), maxOf(1, (it.height * scale).toInt()), true).also { _ -> it.recycle() }
                }
            }
        } finally { retriever.release(); source.close() }
    }.getOrNull()
}
