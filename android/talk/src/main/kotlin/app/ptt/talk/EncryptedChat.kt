package app.ptt.talk

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal enum class ChatContentKind(val wire: Byte) { TEXT(1), FILE(2), VOICE(3), VIDEO(4) }

internal data class ChatAttachment(
    val attachmentId: UUID,
    val fileName: String,
    val mimeType: String,
    val plaintextBytes: Long,
    val durationMs: Int = 0,
    val key: ByteArray,
    val ciphertextSha256: ByteArray,
)

internal data class ChatMessage(
    val messageId: UUID,
    val channelId: UUID,
    val membershipEpoch: Int,
    val sentAt: Instant,
    val senderAci: String,
    val senderDeviceId: Int,
    val kind: ChatContentKind,
    val text: String,
    val attachment: ChatAttachment? = null,
)

internal object EncryptedChatCodec {
    const val MAX_TEXT_BYTES = 4_096
    const val MAX_ATTACHMENT_BYTES = 25 * 1_024 * 1_024
    private val MAGIC = "PTTC".encodeToByteArray()
    private val ATTACHMENT_MAGIC = "PTTA".encodeToByteArray()

    fun boundedUtf8(value: String, maximumBytes: Int): String {
        require(maximumBytes > 0)
        if (value.encodeToByteArray().size <= maximumBytes) return value
        val result = StringBuilder()
        val codePoints = value.codePoints().iterator()
        while (codePoints.hasNext()) {
            val codePoint = codePoints.nextInt()
            val candidate = result.toString() + String(Character.toChars(codePoint))
            if (candidate.encodeToByteArray().size > maximumBytes) break
            result.appendCodePoint(codePoint)
        }
        return result.toString()
    }

    fun encode(message: ChatMessage): ByteArray {
        require(message.membershipEpoch > 0 && message.senderDeviceId in 1..2)
        UUID.fromString(message.senderAci)
        val text = message.text.encodeToByteArray()
        require(text.size <= MAX_TEXT_BYTES)
        require((message.kind == ChatContentKind.TEXT) == (message.attachment == null))
        val attachment = message.attachment
        val extra = if (attachment == null) 0 else {
            val name = attachment.fileName.encodeToByteArray()
            val mime = attachment.mimeType.encodeToByteArray()
            require(name.size in 1..255 && mime.size in 1..127)
            require(attachment.plaintextBytes in 1..MAX_ATTACHMENT_BYTES.toLong())
            require(attachment.durationMs in 0..600_000 && attachment.key.size == 32 && attachment.ciphertextSha256.size == 32)
            16 + 8 + 4 + 2 + 64 + name.size + mime.size
        }
        return ByteBuffer.allocate(4 + 1 + 1 + 16 + 16 + 4 + 8 + 4 + text.size + extra).apply {
            put(MAGIC).put(1).put(message.kind.wire)
            putUuid(message.messageId).putUuid(message.channelId)
            putInt(message.membershipEpoch).putLong(message.sentAt.toEpochMilli()).putInt(text.size).put(text)
            if (attachment != null) {
                val name = attachment.fileName.encodeToByteArray()
                val mime = attachment.mimeType.encodeToByteArray()
                putUuid(attachment.attachmentId).putLong(attachment.plaintextBytes).putInt(attachment.durationMs)
                put(name.size.toByte()).put(mime.size.toByte()).put(attachment.key).put(attachment.ciphertextSha256)
                put(name).put(mime)
            }
        }.array()
    }

    fun decode(bytes: ByteArray, senderAci: String, senderDeviceId: Int): ChatMessage {
        require(bytes.size >= 54 && senderDeviceId in 1..2)
        UUID.fromString(senderAci)
        val buffer = ByteBuffer.wrap(bytes)
        require(ByteArray(4).also(buffer::get).contentEquals(MAGIC) && buffer.get().toInt() == 1)
        val kindWire = buffer.get()
        val kind = ChatContentKind.entries.firstOrNull { it.wire == kindWire } ?: error("invalid chat kind")
        val messageId = buffer.uuid()
        val channelId = buffer.uuid()
        val epoch = buffer.int
        val sentAt = Instant.ofEpochMilli(buffer.long)
        val textLength = buffer.int
        require(epoch > 0 && textLength in 0..MAX_TEXT_BYTES && textLength <= buffer.remaining())
        val text = strictUtf8(ByteArray(textLength).also(buffer::get))
        val attachment = if (kind == ChatContentKind.TEXT) {
            require(!buffer.hasRemaining())
            null
        } else {
            require(buffer.remaining() >= 16 + 8 + 4 + 2 + 64)
            val id = buffer.uuid()
            val size = buffer.long
            val duration = buffer.int
            val nameLength = buffer.get().toInt() and 0xff
            val mimeLength = buffer.get().toInt() and 0xff
            val key = ByteArray(32).also(buffer::get)
            val digest = ByteArray(32).also(buffer::get)
            require(nameLength > 0 && mimeLength > 0 && nameLength + mimeLength == buffer.remaining())
            require(size in 1..MAX_ATTACHMENT_BYTES.toLong() && duration in 0..600_000)
            val name = strictUtf8(ByteArray(nameLength).also(buffer::get))
            val mime = strictUtf8(ByteArray(mimeLength).also(buffer::get))
            ChatAttachment(id, name, mime, size, duration, key, digest)
        }
        return ChatMessage(messageId, channelId, epoch, sentAt, senderAci.lowercase(), senderDeviceId, kind, text, attachment)
    }

    fun sealAttachment(
        plaintext: ByteArray,
        attachmentId: UUID,
        channelId: UUID,
        membershipEpoch: Int,
        key: ByteArray = ByteArray(32).also(SecureRandom()::nextBytes),
    ): Triple<ByteArray, ByteArray, ByteArray> {
        require(plaintext.size in 1..MAX_ATTACHMENT_BYTES && key.size == 32 && membershipEpoch > 0)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(attachmentAad(attachmentId, channelId, membershipEpoch))
        val ciphertext = ATTACHMENT_MAGIC + byteArrayOf(1) + nonce + cipher.doFinal(plaintext)
        return Triple(ciphertext, key.copyOf(), MessageDigest.getInstance("SHA-256").digest(ciphertext))
    }

    fun openAttachment(ciphertext: ByteArray, metadata: ChatAttachment, channelId: UUID, membershipEpoch: Int): ByteArray {
        require(ciphertext.size > 5 + 12 + 16 && ciphertext.copyOfRange(0, 4).contentEquals(ATTACHMENT_MAGIC) && ciphertext[4].toInt() == 1)
        require(MessageDigest.getInstance("SHA-256").digest(ciphertext).contentEquals(metadata.ciphertextSha256))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(metadata.key, "AES"), GCMParameterSpec(128, ciphertext.copyOfRange(5, 17)))
        cipher.updateAAD(attachmentAad(metadata.attachmentId, channelId, membershipEpoch))
        return cipher.doFinal(ciphertext, 17, ciphertext.size - 17).also {
            require(it.size.toLong() == metadata.plaintextBytes)
        }
    }

    private fun attachmentAad(attachmentId: UUID, channelId: UUID, membershipEpoch: Int): ByteArray =
        ByteBuffer.allocate(22 + 16 + 16 + 4).put("PTT-CHAT-ATTACHMENT-V1".encodeToByteArray())
            .putUuid(attachmentId).putUuid(channelId).putInt(membershipEpoch).array()

    private fun strictUtf8(bytes: ByteArray): String =
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()

    private fun ByteBuffer.putUuid(value: UUID): ByteBuffer = putLong(value.mostSignificantBits).putLong(value.leastSignificantBits)
    private fun ByteBuffer.uuid(): UUID = UUID(long, long)
}
