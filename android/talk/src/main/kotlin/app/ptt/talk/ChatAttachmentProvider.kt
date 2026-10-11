package app.ptt.talk

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File

/** Grant-scoped bridge; only explicit random camera targets are writable. */
class ChatAttachmentProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.let(::removeExpiredPreviews)
        return true
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = resolve(requireNotNull(context), uri)
        // Only one explicitly granted, randomly named camera target is writable.
        val access = if (mode == "r") ParcelFileDescriptor.MODE_READ_ONLY else {
            require(file.name.startsWith("capture-") && mode in setOf("w", "wt", "rw", "rwt"))
            ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE
        }
        return ParcelFileDescriptor.open(file, access)
    }

    override fun getType(uri: Uri): String? =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(resolve(requireNotNull(context), uri).extension.lowercase())
            ?: "application/octet-stream"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = resolve(requireNotNull(context), uri)
        return android.database.MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any>(file.name.substringAfter('-'), file.length()))
        }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        private const val PREVIEW_LIFETIME_MS = 15 * 60_000L
        private fun removeExpiredPreviews(context: Context) {
            val staleBefore = System.currentTimeMillis() - PREVIEW_LIFETIME_MS
            File(context.cacheDir, "chat-preview").listFiles()
                ?.filter { it.isFile && it.lastModified() < staleBefore }?.forEach { it.delete() }
        }
        private fun authority(context: Context) = "${context.packageName}.chat-attachments"
        fun write(context: Context, id: String, name: String, bytes: ByteArray): File {
            val root = File(context.cacheDir, "chat-preview").apply { mkdirs() }
            removeExpiredPreviews(context)
            val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "-").take(180).ifBlank { "Attachment" }
            return File(root, "$id-$safe").also { file ->
                file.writeBytes(bytes)
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    removeExpiredPreviews(context.applicationContext)
                }, PREVIEW_LIFETIME_MS + 1000)
            }
        }
        fun uri(context: Context, file: File): Uri {
            require(file.parentFile?.canonicalFile == File(context.cacheDir, "chat-preview").canonicalFile)
            return Uri.Builder().scheme("content").authority(authority(context)).appendPath(file.name).build()
        }
        private fun resolve(context: Context, uri: Uri): File {
            require(uri.authority == authority(context) && uri.pathSegments.size == 1)
            val root = File(context.cacheDir, "chat-preview").canonicalFile
            val file = File(root, uri.pathSegments.single()).canonicalFile
            require(file.parentFile == root && file.isFile)
            return file
        }
    }
}
