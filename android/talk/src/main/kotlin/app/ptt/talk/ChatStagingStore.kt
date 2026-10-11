package app.ptt.talk

import android.content.Context
import android.util.AtomicFile
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Plain selected media never persists in cache; the key lives in encrypted app storage. */
internal class ChatStagingStore(context: Context, account: String) {
    private val root = File(context.filesDir, "chat-staging/" + MessageDigest.getInstance("SHA-256").digest(account.toByteArray()).joinToString("") { "%02x".format(it) }).apply { mkdirs() }
    private val key = synchronized(keyLock) {
        EncryptedSignalProtocolStore.open(context).use { store ->
            store.applicationState("composer-media-key-v1") ?: ByteArray(32).also {
                SecureRandom().nextBytes(it); store.putApplicationState("composer-media-key-v1", it)
            }
        }
    }
    private fun file(channel: String, id: UUID) = File(root, "${UUID.fromString(channel)}-$id.bin")
    fun put(channel: String, id: UUID, bytes: ByteArray) {
        require(bytes.size in 1..25 * 1024 * 1024)
        val file = file(channel, id)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        cipher.updateAAD(file.name.toByteArray())
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(cipher.iv + cipher.doFinal(bytes)); atomic.finishWrite(stream) }
        catch (error: Throwable) { atomic.failWrite(stream); throw error }
    }
    fun get(channel: String, id: UUID): ByteArray {
        val file = file(channel, id)
        val bytes = AtomicFile(file).readFully()
        require(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(file.name.toByteArray())
        return cipher.doFinal(bytes, 12, bytes.size - 12)
    }
    fun discard(channel: String, id: UUID) { AtomicFile(file(channel, id)).delete() }
    companion object { private val keyLock = Any() }
}
