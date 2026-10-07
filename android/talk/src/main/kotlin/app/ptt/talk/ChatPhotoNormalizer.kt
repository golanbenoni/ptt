package app.ptt.talk

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

internal object ChatPhotoNormalizer {
    fun jpeg(data: ByteArray): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unreadable photo" }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 4096) sample *= 2
        val bitmap = requireNotNull(BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }))
        val orientation = runCatching { ExifInterface(ByteArrayInputStream(data)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
        val matrix = Matrix().apply {
            when (orientation) {
                2 -> setScale(-1f, 1f)
                3 -> setRotate(180f)
                4 -> setScale(1f, -1f)
                5 -> { setRotate(90f); postScale(-1f, 1f) }
                6 -> setRotate(90f)
                7 -> { setRotate(-90f); postScale(-1f, 1f) }
                8 -> setRotate(-90f)
            }
            val scale = minOf(1f, 2048f / maxOf(bitmap.width, bitmap.height))
            postScale(scale, scale)
        }
        val normalized = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        return try {
            ByteArrayOutputStream().use { output ->
                check(normalized.compress(Bitmap.CompressFormat.JPEG, 88, output))
                output.toByteArray() // Pixel re-encode intentionally omits EXIF, including GPS.
            }
        } finally { if (normalized !== bitmap) normalized.recycle(); bitmap.recycle() }
    }
}
