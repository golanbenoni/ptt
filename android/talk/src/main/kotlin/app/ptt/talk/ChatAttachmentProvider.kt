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

/** Read-only, grant-scoped bridge from decrypted cache files to the system viewer. */
class ChatAttachmentProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r")
        val file = resolve(requireNotNull(context), uri)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
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
        private fun authority(context: Context) = "${context.packageName}.chat-attachments"
        fun write(context: Context, id: String, name: String, bytes: ByteArray): File {
            val root = File(context.cacheDir, "chat-preview").apply { mkdirs() }
            val staleBefore = System.currentTimeMillis() - 15 * 60_000
            root.listFiles()?.filter { it.isFile && it.lastModified() < staleBefore }?.forEach { it.delete() }
            val safe = name.replace(Regex("[^A-Za-z0-9._ -]"), "-").take(180).ifBlank { "Attachment" }
            return File(root, "$id-$safe").also { it.writeBytes(bytes) }
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
