package app.ptt.media

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end encrypted, self-delimiting history object. The server stores this blob verbatim and
 * never receives the media epoch key. Wrapping the already-SFrame-protected datagrams also binds
 * their ordering and routing headers, which are otherwise authenticated only at the relay hop.
 */
object EncryptedHistory {
    private val MAGIC = byteArrayOf('P'.code.toByte(), 'T'.code.toByte(), 'T'.code.toByte(), 'H'.code.toByte())
    private const val VERSION = 1
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private const val MAX_FRAMES = 1_501
    private val INFO = "PTT Talk encrypted history v1".toByteArray(StandardCharsets.UTF_8)

    fun seal(
        channelId: UUID,
        talkId: UUID,
        membershipEpoch: Int,
        kid: ULong,
        baseKey: ByteArray,
        packets: List<ByteArray>,
        nonce: ByteArray = ByteArray(NONCE_BYTES).also(SecureRandom()::nextBytes),
    ): ByteArray {
        validate(membershipEpoch, baseKey, packets, nonce)
        val prefix = MAGIC + byteArrayOf(VERSION.toByte()) + nonce
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(deriveKey(baseKey), "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(channelId, talkId, membershipEpoch, kid))
        val plaintext = ByteBuffer.allocate(4 + packets.size * MEDIA_DATAGRAM_BYTES)
            .putInt(packets.size)
            .also { output -> packets.forEach(output::put) }
            .array()
        return prefix + cipher.doFinal(plaintext)
    }

    fun open(
        blob: ByteArray,
        channelId: UUID,
        talkId: UUID,
        membershipEpoch: Int,
        kid: ULong,
        baseKey: ByteArray,
    ): List<ByteArray> {
        require(blob.size >= MAGIC.size + 1 + NONCE_BYTES + 4 + TAG_BITS / 8) { "history object is truncated" }
        require(blob.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) { "invalid history magic" }
        require(blob[MAGIC.size].toInt() and 0xff == VERSION) { "unsupported history version" }
        require(membershipEpoch > 0 && baseKey.size == 32) { "invalid history key metadata" }
        val nonceStart = MAGIC.size + 1
        val nonce = blob.copyOfRange(nonceStart, nonceStart + NONCE_BYTES)
        val ciphertext = blob.copyOfRange(nonceStart + NONCE_BYTES, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(deriveKey(baseKey), "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad(channelId, talkId, membershipEpoch, kid))
        val plaintext = cipher.doFinal(ciphertext)
        require(plaintext.size >= 4) { "history plaintext is truncated" }
        val input = ByteBuffer.wrap(plaintext)
        val count = input.int
        require(count in 1..MAX_FRAMES) { "invalid history frame count" }
        require(input.remaining() == count * MEDIA_DATAGRAM_BYTES) { "invalid history object length" }
        return List(count) { ByteArray(MEDIA_DATAGRAM_BYTES).also(input::get) }
    }

    private fun validate(epoch: Int, key: ByteArray, packets: List<ByteArray>, nonce: ByteArray) {
        require(epoch > 0) { "membership epoch must be positive" }
        require(key.size == 32) { "media base key must contain 32 bytes" }
        require(nonce.size == NONCE_BYTES) { "history nonce must contain 12 bytes" }
        require(packets.size in 1..MAX_FRAMES) { "history must contain 1..$MAX_FRAMES frames" }
        require(packets.all { it.size == MEDIA_DATAGRAM_BYTES }) { "history packets must contain 160 bytes" }
    }

    private fun aad(channelId: UUID, talkId: UUID, epoch: Int, kid: ULong): ByteArray =
        ByteBuffer.allocate(4 + 1 + 16 + 16 + 4 + 8)
            .put(MAGIC)
            .put(VERSION.toByte())
            .putLong(channelId.mostSignificantBits)
            .putLong(channelId.leastSignificantBits)
            .putLong(talkId.mostSignificantBits)
            .putLong(talkId.leastSignificantBits)
            .putInt(epoch)
            .putLong(kid.toLong())
            .array()

    private fun deriveKey(inputKey: ByteArray): ByteArray {
        val extract = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
        }.doFinal(inputKey)
        return Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(extract, "HmacSHA256"))
        }.doFinal(INFO + byteArrayOf(1))
    }
}
