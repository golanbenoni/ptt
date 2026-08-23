package app.ptt.media

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Per-frame AES-GCM used until the Rust SFrame crate (PR4).
 *
 * Wire: 8-byte big-endian counter || ciphertext+tag (16-byte tag).
 * AAD is the 36-byte layout frozen in the design: channel/talk UUID || sender_demux.
 */
class AesGcmFrames(private val key: ByteArray) {
    init {
        require(key.size == 16 || key.size == 32) { "AES-128 or AES-256 key" }
    }

    fun encrypt(counter: Long, aad: ByteArray, plaintext: ByteArray): ByteArray {
        val nonce = nonce(counter)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad)
        val ct = cipher.doFinal(plaintext)
        return ByteBuffer.allocate(8 + ct.size).putLong(counter).put(ct).array()
    }

    fun decrypt(aad: ByteArray, packet: ByteArray): ByteArray {
        require(packet.size > 8 + 16) { "short frame" }
        val buf = ByteBuffer.wrap(packet)
        val counter = buf.long
        val ct = ByteArray(packet.size - 8)
        buf.get(ct)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce(counter)))
        cipher.updateAAD(aad)
        return cipher.doFinal(ct)
    }

    companion object {
        const val TAG_BITS = 128
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        fun newKey(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

        fun aad(channelOrZero: UUID, talkId: UUID, senderDemux: Int): ByteArray {
            val buf = ByteBuffer.allocate(36)
            buf.putLong(channelOrZero.mostSignificantBits)
            buf.putLong(channelOrZero.leastSignificantBits)
            buf.putLong(talkId.mostSignificantBits)
            buf.putLong(talkId.leastSignificantBits)
            buf.putInt(senderDemux)
            return buf.array()
        }

        private fun nonce(counter: Long): ByteArray {
            val n = ByteArray(12)
            ByteBuffer.wrap(n, 4, 8).putLong(counter)
            return n
        }
    }
}
