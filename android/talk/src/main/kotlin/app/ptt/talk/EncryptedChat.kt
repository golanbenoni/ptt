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

internal data class ChatThumbnail(
    val thumbnailId: UUID,
    val mimeType: String,
    val plaintextBytes: Int,
    val width: Int,
    val height: Int,
    val key: ByteArray,
    val ciphertextSha256: ByteArray,
)

internal data class ChatAttachment(
    val attachmentId: UUID,
    val fileName: String,
    val mimeType: String,
    val plaintextBytes: Long,
    val durationMs: Int = 0,
    /** Pairwise-encrypted normalized amplitude samples; never service-visible. */
    val waveform: ByteArray = byteArrayOf(),
    val key: ByteArray,
    val ciphertextSha256: ByteArray,
    val thumbnail: ChatThumbnail? = null,
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

/**
 * Mentions remain inside the pairwise-encrypted message text. The token uses a
 * 48-bit SHA-256-derived pseudonym instead of exposing a raw account UUID, and
 * older clients safely display the token as ordinary text.
 */
internal data class ChatMention(val aci: String, val tag: String) {
    val token: String get() = "@teammate-${tag.lowercase()}"
    val label: String get() = "Teammate ${tag.take(4).uppercase()}"
}

internal data class ChatMentionSegment(val text: String, val isMention: Boolean)

internal object ChatMentions {
    private val tokenPattern = Regex("(?i)@teammate-([0-9a-f]{12})(?![0-9a-z])")

    fun mention(aci: String): ChatMention? = runCatching {
        val canonical = UUID.fromString(aci).toString().lowercase()
        val digest = MessageDigest.getInstance("SHA-256").digest(canonical.encodeToByteArray())
        ChatMention(canonical, digest.take(6).joinToString("") { "%02x".format(it.toInt() and 0xff) })
    }.getOrNull()

    fun suggestions(acis: Collection<String>, localAci: String, draft: String): List<ChatMention> {
        val query = activeQuery(draft) ?: return emptyList()
        return acis.asSequence().mapNotNull(::mention)
            .filterNot { it.aci.equals(localAci, true) }
            .distinctBy { it.aci }
            .filter { query.isBlank() || it.label.contains(query, true) || it.tag.contains(query, true) }
            .sortedBy { it.label }
            .toList()
    }

    fun insert(draft: String, mention: ChatMention): String {
        val at = activeAt(draft) ?: return draft
        return draft.substring(0, at) + mention.token + " "
    }

    fun containsLocalMention(text: String, localAci: String): Boolean {
        val local = mention(localAci) ?: return false
        return tokenPattern.findAll(text).any { it.groupValues[1].equals(local.tag, true) }
    }

    fun containsNewLocalMention(
        conversation: Collection<ChatConversationMessage>,
        previouslyUnreadMessageIds: Set<UUID>,
        localAci: String,
    ): Boolean = conversation.any {
        it.isUnread && it.message.messageId !in previouslyUnreadMessageIds &&
            containsLocalMention(it.displayText, localAci)
    }

    fun rendered(text: String): String = segments(text).joinToString("") { it.text }

    fun segments(text: String): List<ChatMentionSegment> {
        val matches = tokenPattern.findAll(text).toList()
        if (matches.isEmpty()) return listOf(ChatMentionSegment(text, false))
        val output = mutableListOf<ChatMentionSegment>()
        var offset = 0
        matches.forEach { match ->
            if (match.range.first > offset) output += ChatMentionSegment(text.substring(offset, match.range.first), false)
            output += ChatMentionSegment("@Teammate ${match.groupValues[1].take(4).uppercase()}", true)
            offset = match.range.last + 1
        }
        if (offset < text.length) output += ChatMentionSegment(text.substring(offset), false)
        return output
    }

    private fun activeQuery(draft: String): String? {
        val at = activeAt(draft) ?: return null
        return draft.substring(at + 1)
    }

    private fun activeAt(draft: String): Int? {
        val at = draft.lastIndexOf('@')
        if (at < 0 || (at > 0 && !draft[at - 1].isWhitespace())) return null
        val suffix = draft.substring(at + 1)
        return at.takeIf { suffix.none(Char::isWhitespace) && suffix.all { it.isLetterOrDigit() || it == '_' || it == '-' } }
    }
}

internal enum class ChatEventKind(val wire: Byte) {
    MESSAGE(1),
    DELIVERED(2),
    READ(3),
    PLAYED(4),
    REACTION(5),
    REMOVE_REACTION(6),
    EDIT(7),
    DELETE(8),
    PIN(9),
    UNPIN(10),
}

/** Opaque, pairwise-encrypted causal event. The service never sees its payload. */
internal data class ChatEvent(
    val eventId: UUID,
    val channelId: UUID,
    val membershipEpoch: Int,
    val sentAt: Instant,
    val senderAci: String,
    val senderDeviceId: Int,
    val kind: ChatEventKind,
    val targetMessageId: UUID? = null,
    val replyToMessageId: UUID? = null,
    val value: String = "",
    val message: ChatMessage? = null,
) {
    companion object {
        fun message(message: ChatMessage, replyTo: UUID? = null) = ChatEvent(
            eventId = message.messageId,
            channelId = message.channelId,
            membershipEpoch = message.membershipEpoch,
            sentAt = message.sentAt,
            senderAci = message.senderAci,
            senderDeviceId = message.senderDeviceId,
            kind = ChatEventKind.MESSAGE,
            replyToMessageId = replyTo,
            message = message,
        )
    }
}

internal enum class ChatReceiptState { DELIVERED, READ, PLAYED }

internal enum class ChatSendState { QUEUED, SENDING, FAILED, SENT, DELIVERED, READ, PLAYED }

internal data class ChatConversationMessage(
    val message: ChatMessage,
    val replyToMessageId: UUID?,
    val editedText: String?,
    val isDeleted: Boolean,
    val reactions: Map<String, String>,
    val receipts: Map<String, ChatReceiptState>,
    val isUnread: Boolean,
    val isPinned: Boolean = false,
    val isStarred: Boolean = false,
    val sendState: ChatSendState? = null,
) {
    val displayText: String get() = if (isDeleted) "" else editedText ?: message.text
}

internal object ChatEventReducer {
    fun reduce(events: List<ChatEvent>, channelId: UUID, localAci: String): List<ChatConversationMessage> {
        val ordered = events.filter { it.channelId == channelId }
            .sortedWith(compareBy<ChatEvent>({ it.sentAt }, { it.eventId.toString() }))
        val states = linkedMapOf<UUID, MutableConversationState>()
        ordered.filter { it.kind == ChatEventKind.MESSAGE }.forEach { event ->
            val message = event.message ?: return@forEach
            states.putIfAbsent(message.messageId, MutableConversationState(message, event.replyToMessageId))
        }
        ordered.filter { it.kind != ChatEventKind.MESSAGE }.forEach { event ->
            val target = event.targetMessageId ?: return@forEach
            val state = states[target] ?: return@forEach
            if (event.sentAt.isBefore(state.message.sentAt)) return@forEach
            val source = "${event.senderAci.lowercase()}:${event.senderDeviceId}"
            when (event.kind) {
                ChatEventKind.MESSAGE -> Unit
                ChatEventKind.EDIT -> if (event.senderAci.equals(state.message.senderAci, true) && !state.deleted) {
                    state.editedText = event.value
                }
                ChatEventKind.DELETE -> if (event.senderAci.equals(state.message.senderAci, true)) {
                    state.deleted = true
                    state.editedText = null
                    state.reactions.clear()
                    state.pinned = false
                }
                ChatEventKind.REACTION -> if (!state.deleted) state.reactions[event.senderAci.lowercase()] = event.value
                ChatEventKind.REMOVE_REACTION -> state.reactions.remove(event.senderAci.lowercase())
                ChatEventKind.DELIVERED -> state.receipts[source] = maxOf(
                    state.receipts[source] ?: ChatReceiptState.DELIVERED, ChatReceiptState.DELIVERED,
                )
                ChatEventKind.READ -> state.receipts[source] = maxOf(
                    state.receipts[source] ?: ChatReceiptState.DELIVERED, ChatReceiptState.READ,
                )
                ChatEventKind.PLAYED -> state.receipts[source] = maxOf(
                    state.receipts[source] ?: ChatReceiptState.DELIVERED, ChatReceiptState.PLAYED,
                )
                ChatEventKind.PIN -> if (!state.deleted) state.pinned = true
                ChatEventKind.UNPIN -> state.pinned = false
            }
        }
        val canonicalLocalAci = localAci.lowercase()
        return states.values.map { state ->
            val locallyRead = state.message.senderAci.lowercase() == canonicalLocalAci || state.receipts.any { (source, receipt) ->
                source.startsWith("$canonicalLocalAci:") && receipt >= ChatReceiptState.READ
            }
            ChatConversationMessage(
                state.message, state.replyTo, state.editedText, state.deleted,
                state.reactions.toMap(), state.receipts.toMap(), !locallyRead, state.pinned,
            )
        }.sortedWith(compareBy({ it.message.sentAt }, { it.message.messageId.toString() }))
    }

    private data class MutableConversationState(
        val message: ChatMessage,
        val replyTo: UUID?,
        var editedText: String? = null,
        var deleted: Boolean = false,
        val reactions: MutableMap<String, String> = linkedMapOf(),
        val receipts: MutableMap<String, ChatReceiptState> = linkedMapOf(),
        var pinned: Boolean = false,
    )
}

internal object EncryptedChatCodec {
    const val MAX_TEXT_BYTES = 4_096
    const val MAX_ATTACHMENT_BYTES = 25 * 1_024 * 1_024
    const val MAX_THUMBNAIL_BYTES = 256 * 1_024
    const val MAX_REACTION_BYTES = 64
    private val MAGIC = "PTTC".encodeToByteArray()
    private val EVENT_MAGIC = "PTTE".encodeToByteArray()
    private val ATTACHMENT_MAGIC = "PTTA".encodeToByteArray()
    private val THUMBNAIL_MAGIC = "PTTN".encodeToByteArray()
    private val LOCAL_BUNDLE_MAGIC = "PTTL".encodeToByteArray()
    private val ZERO_UUID = UUID(0, 0)

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
            val thumbnailMime = attachment.thumbnail?.mimeType?.encodeToByteArray() ?: byteArrayOf()
            require(name.size in 1..255 && mime.size in 1..127)
            require(attachment.plaintextBytes in 1..MAX_ATTACHMENT_BYTES.toLong())
            require(attachment.durationMs in 0..600_000 && attachment.waveform.size <= 64)
            require(attachment.key.size == 32 && attachment.ciphertextSha256.size == 32)
            attachment.thumbnail?.let { thumbnail ->
                require(thumbnailMime.size in 1..63 && thumbnail.plaintextBytes in 1..MAX_THUMBNAIL_BYTES)
                require(thumbnail.width in 1..0xffff && thumbnail.height in 1..0xffff)
                require(thumbnail.key.size == 32 && thumbnail.ciphertextSha256.size == 32)
            }
            16 + 8 + 4 + 3 + (if (attachment.thumbnail == null) 0 else 1) + 64 +
                attachment.waveform.size +
                (if (attachment.thumbnail == null) 0 else 16 + 4 + 2 + 2 + 64 + thumbnailMime.size) +
                name.size + mime.size
        }
        return ByteBuffer.allocate(4 + 1 + 1 + 16 + 16 + 4 + 8 + 4 + text.size + extra).apply {
            put(MAGIC).put((if (attachment == null) 1 else if (attachment.thumbnail == null) 2 else 3).toByte())
                .put(message.kind.wire)
            putUuid(message.messageId).putUuid(message.channelId)
            putInt(message.membershipEpoch).putLong(message.sentAt.toEpochMilli()).putInt(text.size).put(text)
            if (attachment != null) {
                val name = attachment.fileName.encodeToByteArray()
                val mime = attachment.mimeType.encodeToByteArray()
                val thumbnailMime = attachment.thumbnail?.mimeType?.encodeToByteArray() ?: byteArrayOf()
                putUuid(attachment.attachmentId).putLong(attachment.plaintextBytes).putInt(attachment.durationMs)
                put(name.size.toByte()).put(mime.size.toByte()).put(attachment.waveform.size.toByte())
                if (attachment.thumbnail != null) put(thumbnailMime.size.toByte())
                put(attachment.key).put(attachment.ciphertextSha256).put(attachment.waveform)
                attachment.thumbnail?.let { thumbnail ->
                    putUuid(thumbnail.thumbnailId).putInt(thumbnail.plaintextBytes)
                    putShort(thumbnail.width.toShort()).putShort(thumbnail.height.toShort())
                    put(thumbnail.key).put(thumbnail.ciphertextSha256).put(thumbnailMime)
                }
                put(name).put(mime)
            }
        }.array()
    }

    fun decode(bytes: ByteArray, senderAci: String, senderDeviceId: Int): ChatMessage {
        require(bytes.size >= 54 && senderDeviceId in 1..2)
        UUID.fromString(senderAci)
        val buffer = ByteBuffer.wrap(bytes)
        require(ByteArray(4).also(buffer::get).contentEquals(MAGIC))
        val version = buffer.get().toInt()
        require(version in 1..3)
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
            val lengthBytes = when (version) { 1 -> 2; 2 -> 3; else -> 4 }
            require(buffer.remaining() >= 16 + 8 + 4 + lengthBytes + 64)
            val id = buffer.uuid()
            val size = buffer.long
            val duration = buffer.int
            val nameLength = buffer.get().toInt() and 0xff
            val mimeLength = buffer.get().toInt() and 0xff
            val waveformLength = if (version >= 2) buffer.get().toInt() and 0xff else 0
            val thumbnailMimeLength = if (version == 3) buffer.get().toInt() and 0xff else 0
            val key = ByteArray(32).also(buffer::get)
            val digest = ByteArray(32).also(buffer::get)
            require(nameLength > 0 && mimeLength > 0 && waveformLength <= 64)
            val thumbnailWireLength = if (version == 3) 16 + 4 + 2 + 2 + 64 + thumbnailMimeLength else 0
            require(waveformLength + thumbnailWireLength + nameLength + mimeLength == buffer.remaining())
            require(size in 1..MAX_ATTACHMENT_BYTES.toLong() && duration in 0..600_000)
            val waveform = ByteArray(waveformLength).also(buffer::get)
            val thumbnail = if (version == 3) {
                require(thumbnailMimeLength in 1..63)
                val thumbnailId = buffer.uuid()
                val thumbnailSize = buffer.int
                val width = buffer.short.toInt() and 0xffff
                val height = buffer.short.toInt() and 0xffff
                val thumbnailKey = ByteArray(32).also(buffer::get)
                val thumbnailDigest = ByteArray(32).also(buffer::get)
                val thumbnailMime = strictUtf8(ByteArray(thumbnailMimeLength).also(buffer::get))
                require(thumbnailSize in 1..MAX_THUMBNAIL_BYTES && width > 0 && height > 0)
                ChatThumbnail(thumbnailId, thumbnailMime, thumbnailSize, width, height, thumbnailKey, thumbnailDigest)
            } else null
            val name = strictUtf8(ByteArray(nameLength).also(buffer::get))
            val mime = strictUtf8(ByteArray(mimeLength).also(buffer::get))
            require(!buffer.hasRemaining())
            ChatAttachment(id, name, mime, size, duration, waveform, key, digest, thumbnail)
        }
        return ChatMessage(messageId, channelId, epoch, sentAt, senderAci.lowercase(), senderDeviceId, kind, text, attachment)
    }

    fun encodeEvent(event: ChatEvent): ByteArray {
        require(event.membershipEpoch > 0 && event.senderDeviceId in 1..2 && event.senderAci == event.senderAci.lowercase())
        UUID.fromString(event.senderAci)
        val payload = when (event.kind) {
            ChatEventKind.MESSAGE -> {
                val message = requireNotNull(event.message)
                require(event.targetMessageId == null && event.value.isEmpty())
                require(event.eventId == message.messageId && event.channelId == message.channelId)
                require(event.membershipEpoch == message.membershipEpoch && event.sentAt.toEpochMilli() == message.sentAt.toEpochMilli())
                require(event.senderAci.equals(message.senderAci, ignoreCase = true) && event.senderDeviceId == message.senderDeviceId)
                encode(message)
            }
            ChatEventKind.DELIVERED, ChatEventKind.READ, ChatEventKind.PLAYED, ChatEventKind.DELETE,
            ChatEventKind.PIN, ChatEventKind.UNPIN -> {
                require(event.message == null && event.targetMessageId != null)
                require(event.replyToMessageId == null && event.value.isEmpty())
                byteArrayOf()
            }
            ChatEventKind.REACTION -> {
                val value = event.value.encodeToByteArray()
                require(event.message == null && event.targetMessageId != null && event.replyToMessageId == null)
                require(value.size in 1..MAX_REACTION_BYTES)
                value
            }
            ChatEventKind.REMOVE_REACTION -> {
                require(event.message == null && event.targetMessageId != null)
                require(event.replyToMessageId == null && event.value.isEmpty())
                byteArrayOf()
            }
            ChatEventKind.EDIT -> {
                val value = event.value.encodeToByteArray()
                require(event.message == null && event.targetMessageId != null && event.replyToMessageId == null)
                require(value.size in 1..MAX_TEXT_BYTES)
                value
            }
        }
        return ByteBuffer.allocate(86 + payload.size).apply {
            put(EVENT_MAGIC).put(1).put(event.kind.wire)
            putUuid(event.eventId).putUuid(event.channelId)
            putInt(event.membershipEpoch).putLong(event.sentAt.toEpochMilli())
            putOptionalUuid(event.targetMessageId).putOptionalUuid(event.replyToMessageId)
            putInt(payload.size).put(payload)
        }.array()
    }

    fun decodeEvent(bytes: ByteArray, senderAci: String, senderDeviceId: Int): ChatEvent {
        require(bytes.size >= 86 && senderDeviceId in 1..2)
        UUID.fromString(senderAci)
        val buffer = ByteBuffer.wrap(bytes)
        require(ByteArray(4).also(buffer::get).contentEquals(EVENT_MAGIC) && buffer.get().toInt() == 1)
        val kindWire = buffer.get()
        val kind = ChatEventKind.entries.firstOrNull { it.wire == kindWire } ?: error("invalid chat event kind")
        val eventId = buffer.uuid()
        val channelId = buffer.uuid()
        val epoch = buffer.int
        val sentAt = Instant.ofEpochMilli(buffer.long)
        val target = buffer.optionalUuid()
        val reply = buffer.optionalUuid()
        val payloadLength = buffer.int
        require(eventId != ZERO_UUID && channelId != ZERO_UUID && epoch > 0)
        require(payloadLength >= 0 && payloadLength == buffer.remaining())
        val payload = ByteArray(payloadLength).also(buffer::get)
        val message = if (kind == ChatEventKind.MESSAGE) decode(payload, senderAci, senderDeviceId) else null
        val value = if (kind == ChatEventKind.MESSAGE) "" else strictUtf8(payload)
        val event = ChatEvent(
            eventId, channelId, epoch, sentAt, senderAci.lowercase(), senderDeviceId,
            kind, target, reply, value, message,
        )
        require(encodeEvent(event).contentEquals(bytes))
        return event
    }

    fun decodeEventOrLegacyMessage(bytes: ByteArray, senderAci: String, senderDeviceId: Int): ChatEvent =
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(MAGIC)) {
            ChatEvent.message(decode(bytes, senderAci, senderDeviceId))
        } else {
            decodeEvent(bytes, senderAci, senderDeviceId)
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

    /** Local-only compatibility wrapper for the protected single-ciphertext cache slot. */
    fun packAttachmentCiphertexts(attachment: ByteArray?, thumbnail: ByteArray?): ByteArray {
        require(attachment != null || thumbnail != null)
        require((attachment?.size ?: 0) <= MAX_ATTACHMENT_BYTES + 64)
        require((thumbnail?.size ?: 0) <= MAX_THUMBNAIL_BYTES + 64)
        if (attachment != null && thumbnail == null) return attachment.copyOf()
        return ByteBuffer.allocate(13 + (attachment?.size ?: 0) + (thumbnail?.size ?: 0)).apply {
            put(LOCAL_BUNDLE_MAGIC).put(1).putInt(attachment?.size ?: 0).putInt(thumbnail?.size ?: 0)
            attachment?.let(::put)
            thumbnail?.let(::put)
        }.array()
    }

    fun unpackAttachmentCiphertexts(bytes: ByteArray): Pair<ByteArray?, ByteArray?> {
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(ATTACHMENT_MAGIC)) {
            return bytes.copyOf() to null
        }
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(THUMBNAIL_MAGIC)) {
            return null to bytes.copyOf()
        }
        require(bytes.size >= 13)
        val buffer = ByteBuffer.wrap(bytes)
        require(ByteArray(4).also(buffer::get).contentEquals(LOCAL_BUNDLE_MAGIC) && buffer.get().toInt() == 1)
        val attachmentCount = buffer.int
        val thumbnailCount = buffer.int
        require(attachmentCount in 0..MAX_ATTACHMENT_BYTES + 64)
        require(thumbnailCount in 0..MAX_THUMBNAIL_BYTES + 64)
        require(attachmentCount > 0 || thumbnailCount > 0)
        require(attachmentCount + thumbnailCount == buffer.remaining())
        val attachment = if (attachmentCount == 0) null else ByteArray(attachmentCount).also(buffer::get)
        val thumbnail = if (thumbnailCount == 0) null else ByteArray(thumbnailCount).also(buffer::get)
        return attachment to thumbnail
    }

    fun sealThumbnail(
        plaintext: ByteArray,
        thumbnailId: UUID,
        channelId: UUID,
        membershipEpoch: Int,
        key: ByteArray = ByteArray(32).also(SecureRandom()::nextBytes),
    ): Triple<ByteArray, ByteArray, ByteArray> {
        require(plaintext.size in 1..MAX_THUMBNAIL_BYTES && key.size == 32 && membershipEpoch > 0)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = ByteArray(12).also(SecureRandom()::nextBytes)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(thumbnailAad(thumbnailId, channelId, membershipEpoch))
        val ciphertext = THUMBNAIL_MAGIC + byteArrayOf(1) + nonce + cipher.doFinal(plaintext)
        return Triple(ciphertext, key.copyOf(), MessageDigest.getInstance("SHA-256").digest(ciphertext))
    }

    fun openThumbnail(
        ciphertext: ByteArray,
        metadata: ChatThumbnail,
        channelId: UUID,
        membershipEpoch: Int,
    ): ByteArray {
        require(ciphertext.size > 5 + 12 + 16 && ciphertext.copyOfRange(0, 4).contentEquals(THUMBNAIL_MAGIC) &&
            ciphertext[4].toInt() == 1)
        require(metadata.key.size == 32 && metadata.plaintextBytes in 1..MAX_THUMBNAIL_BYTES)
        require(MessageDigest.getInstance("SHA-256").digest(ciphertext).contentEquals(metadata.ciphertextSha256))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(metadata.key, "AES"), GCMParameterSpec(128, ciphertext.copyOfRange(5, 17)))
        cipher.updateAAD(thumbnailAad(metadata.thumbnailId, channelId, membershipEpoch))
        return cipher.doFinal(ciphertext, 17, ciphertext.size - 17).also {
            require(it.size == metadata.plaintextBytes)
        }
    }

    private fun attachmentAad(attachmentId: UUID, channelId: UUID, membershipEpoch: Int): ByteArray =
        ByteBuffer.allocate(22 + 16 + 16 + 4).put("PTT-CHAT-ATTACHMENT-V1".encodeToByteArray())
            .putUuid(attachmentId).putUuid(channelId).putInt(membershipEpoch).array()

    private fun thumbnailAad(thumbnailId: UUID, channelId: UUID, membershipEpoch: Int): ByteArray =
        ByteBuffer.allocate(21 + 16 + 16 + 4).put("PTT-CHAT-THUMBNAIL-V1".encodeToByteArray())
            .putUuid(thumbnailId).putUuid(channelId).putInt(membershipEpoch).array()

    private fun strictUtf8(bytes: ByteArray): String =
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()

    private fun ByteBuffer.putUuid(value: UUID): ByteBuffer = putLong(value.mostSignificantBits).putLong(value.leastSignificantBits)
    private fun ByteBuffer.uuid(): UUID = UUID(long, long)
    private fun ByteBuffer.putOptionalUuid(value: UUID?): ByteBuffer = putUuid(value ?: ZERO_UUID)
    private fun ByteBuffer.optionalUuid(): UUID? = uuid().let { if (it == ZERO_UUID) null else it }
}
