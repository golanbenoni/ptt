package app.ptt.talk

import android.content.Context
import app.ptt.crypto.persistence.EncryptedChatEventRecord
import app.ptt.crypto.persistence.EncryptedChatOutboxRecord
import app.ptt.crypto.persistence.EncryptedChatRecord
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.nio.ByteBuffer
import java.time.Instant
import java.util.UUID
import org.signal.libsignal.protocol.DuplicateMessageException
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException

internal data class ChatConversationPreferences(
    val isMuted: Boolean = false,
    val isPinned: Boolean = false,
    val isArchived: Boolean = false,
)

internal enum class ChatSignalFailureDisposition {
    RETRY,
    ACKNOWLEDGE,
    FAIL;

    companion object {
        fun classify(error: Exception): ChatSignalFailureDisposition = when (error) {
            is NoSessionException -> RETRY
            is DuplicateMessageException, is InvalidKeyIdException -> ACKNOWLEDGE
            else -> FAIL
        }
    }
}

internal class EncryptedChatClient(
    context: Context,
    private val session: DeviceSession,
    injectedDeliveryFailures: Int = 0,
) {
    private val app = context.applicationContext
    private val api = ControlApi(session.serverUrl)
    private val crypto = PersistentPairwiseCrypto(app, session)
    private var remainingInjectedDeliveryFailures = injectedDeliveryFailures.coerceAtLeast(0)

    fun messages(channelId: String): List<ChatMessage> =
        conversation(channelId).map { it.message }

    fun draft(channelId: String): String =
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.applicationState(draftKey(channelId))?.toString(Charsets.UTF_8).orEmpty()
        }

    fun saveDraft(channelId: String, value: String) {
        val bounded = EncryptedChatCodec.boundedUtf8(value, 4_096)
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.putApplicationState(draftKey(channelId), bounded.toByteArray(Charsets.UTF_8))
        }
    }

    fun preferences(channelId: String): ChatConversationPreferences =
        EncryptedSignalProtocolStore.open(app).use { store ->
            val flags = store.applicationState(preferencesKey(channelId))?.firstOrNull()?.toInt() ?: 0
            ChatConversationPreferences(
                isMuted = flags and 1 != 0,
                isPinned = flags and 2 != 0,
                isArchived = flags and 4 != 0,
            )
        }

    fun savePreferences(channelId: String, value: ChatConversationPreferences) {
        val flags = (if (value.isMuted) 1 else 0) or
            (if (value.isPinned) 2 else 0) or (if (value.isArchived) 4 else 0)
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.putApplicationState(preferencesKey(channelId), byteArrayOf(flags.toByte()))
        }
    }

    private fun draftKey(channelId: String): String =
        "chat-draft-v1-${UUID.fromString(channelId).toString().lowercase()}"

    private fun preferencesKey(channelId: String): String =
        "chat-preferences-v1-${UUID.fromString(channelId).toString().lowercase()}"

    fun conversation(channelId: String): List<ChatConversationMessage> =
        EncryptedSignalProtocolStore.open(app).use { store ->
            val starred = store.applicationState(starredKey(channelId))
                ?.toString(Charsets.UTF_8).orEmpty().lineSequence()
                .mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }.toSet()
            val storedEvents = store.chatEvents(channelId).mapNotNull { record ->
                runCatching {
                    EncryptedChatCodec.decodeEventOrLegacyMessage(record.payload, record.senderAci, record.senderDeviceId)
                }.getOrNull()
            }
            val known = storedEvents.mapTo(mutableSetOf()) { it.eventId }
            val legacy = store.chatRecords(channelId).mapNotNull { record ->
                runCatching {
                    EncryptedChatCodec.decodeEventOrLegacyMessage(record.payload, record.senderAci, record.senderDeviceId)
                }.getOrNull()?.takeIf { known.add(it.eventId) }
            }
            val pending = store.chatOutbox().associate { it.eventId to it.state }
            ChatEventReducer.reduce(storedEvents + legacy, UUID.fromString(channelId), session.aci).map { item ->
                val state = if (item.message.senderAci.equals(session.aci, true)) {
                    when (pending[item.message.messageId.toString()]) {
                        "queued" -> ChatSendState.QUEUED
                        "sending" -> ChatSendState.SENDING
                        "failed" -> ChatSendState.FAILED
                        else -> when (item.receipts.values.maxOrNull()) {
                            ChatReceiptState.PLAYED -> ChatSendState.PLAYED
                            ChatReceiptState.READ -> ChatSendState.READ
                            ChatReceiptState.DELIVERED -> ChatSendState.DELIVERED
                            null -> ChatSendState.SENT
                        }
                    }
                } else null
                item.copy(isStarred = item.message.messageId in starred, sendState = state)
            }
        }

    fun setStarred(channelId: String, messageId: UUID, starred: Boolean) {
        EncryptedSignalProtocolStore.open(app).use { store ->
            val key = starredKey(channelId)
            val values = store.applicationState(key)?.toString(Charsets.UTF_8).orEmpty()
                .lineSequence().mapNotNull { runCatching { UUID.fromString(it) }.getOrNull() }.toMutableSet()
            if (starred) values += messageId else values -= messageId
            store.putApplicationState(key, values.map(UUID::toString).sorted().joinToString("\n").toByteArray())
        }
    }

    private fun starredKey(channelId: String): String =
        "chat-starred-v1-${UUID.fromString(channelId).toString().lowercase()}"

    fun unreadCount(channelId: String): Int = conversation(channelId).count { it.isUnread }

    fun sendText(text: String, channel: ChannelSummary, replyTo: UUID? = null): ChatMessage =
        send(ChatContentKind.TEXT, text, null, null, channel, replyTo)

    fun sendAttachment(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        kind: ChatContentKind,
        durationMs: Int = 0,
        waveform: ByteArray = byteArrayOf(),
        thumbnailData: ByteArray? = null,
        thumbnailMimeType: String = "image/jpeg",
        thumbnailWidth: Int = 0,
        thumbnailHeight: Int = 0,
        caption: String = "",
        channel: ChannelSummary,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ): ChatMessage {
        require(kind != ChatContentKind.TEXT)
        val channelId = UUID.fromString(channel.channelId)
        val attachmentId = UUID.randomUUID()
        val sealed = EncryptedChatCodec.sealAttachment(data, attachmentId, channelId, channel.membershipEpoch)
        val thumbnailSealed = thumbnailData?.let {
            require(thumbnailWidth > 0 && thumbnailHeight > 0)
            val thumbnailId = UUID.randomUUID()
            val sealedThumbnail = EncryptedChatCodec.sealThumbnail(
                it, thumbnailId, channelId, channel.membershipEpoch,
            )
            ChatThumbnail(
                thumbnailId,
                EncryptedChatCodec.boundedUtf8(thumbnailMimeType, 63).ifBlank { "image/jpeg" },
                it.size, thumbnailWidth, thumbnailHeight, sealedThumbnail.second, sealedThumbnail.third,
            ) to sealedThumbnail.first
        }
        val attachment = ChatAttachment(
            attachmentId,
            EncryptedChatCodec.boundedUtf8(fileName, 255).ifBlank { "Attachment" },
            EncryptedChatCodec.boundedUtf8(mimeType, 127).ifBlank { "application/octet-stream" },
            data.size.toLong(), durationMs, waveform.copyOf(),
            sealed.second, sealed.third, thumbnailSealed?.first,
        )
        return send(
            kind, caption, attachment,
            EncryptedChatCodec.packAttachmentCiphertexts(sealed.first, thumbnailSealed?.second), channel,
            onProgress = onProgress, isCancelled = isCancelled,
        )
    }

    fun poll(channels: List<ChannelSummary>): Int {
        retryPending(channels)
        val items = api.chatItems(session)
        if (items.isEmpty()) return 0
        val acknowledged = mutableListOf<String>()
        val deliveredReceipts = mutableListOf<Pair<UUID, ChannelSummary>>()
        var accepted = 0
        items.forEach { item ->
            val channel = channels.firstOrNull { it.channelId.equals(item.channelId, ignoreCase = true) }
            if (channel == null || channel.membershipEpoch != item.membershipEpoch) {
                acknowledged += item.itemId
                return@forEach
            }
            try {
                val devices = api.channelDevices(session, channel.channelId)
                val opened = crypto.decryptDataEnvelope(item.envelope, devices)
                val event = EncryptedChatCodec.decodeEventOrLegacyMessage(
                    opened.plaintext, opened.senderAci, opened.senderDeviceId,
                )
                require(event.eventId.toString().equals(item.messageId, ignoreCase = true))
                require(event.channelId.toString().equals(item.channelId, ignoreCase = true))
                require(event.membershipEpoch == item.membershipEpoch)
                val now = Instant.now()
                require(!event.sentAt.isAfter(now.plusSeconds(300)))
                require(!event.sentAt.isBefore(now.minusSeconds(channel.retentionDays * 86_400L + 86_400L)))
                save(event, opened.plaintext, channel.retentionDays, null)
                if (event.kind == ChatEventKind.MESSAGE && !event.senderAci.equals(session.aci, true)) {
                    deliveredReceipts += event.eventId to channel
                }
                acknowledged += item.itemId
                accepted += 1
            } catch (_: IllegalArgumentException) {
                // Malformed authenticated payloads cannot become valid on retry.
                acknowledged += item.itemId
            } catch (error: Exception) {
                when (ChatSignalFailureDisposition.classify(error)) {
                    ChatSignalFailureDisposition.RETRY -> {
                        // Keep an overtaking regular message until its prekey
                        // message establishes the domain-separated session.
                        return@forEach
                    }
                    ChatSignalFailureDisposition.ACKNOWLEDGE -> {
                        // Replays and messages referencing retired prekeys can
                        // never become valid and must not starve newer items.
                        acknowledged += item.itemId
                    }
                    ChatSignalFailureDisposition.FAIL -> throw error
                }
            }
        }
        if (acknowledged.isNotEmpty()) api.acknowledgeChat(session, acknowledged)
        deliveredReceipts.forEach { (messageId, channel) ->
            runCatching { sendReceipt(ChatEventKind.DELIVERED, messageId, channel) }
        }
        return accepted
    }

    fun attachmentData(
        message: ChatMessage,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ): ByteArray {
        val attachment = requireNotNull(message.attachment)
        val cached = EncryptedSignalProtocolStore.open(app).use { it.chatRecord(message.messageId.toString())?.attachmentCiphertext }
        var ciphertexts = cached?.let(EncryptedChatCodec::unpackAttachmentCiphertexts) ?: (null to null)
        if (ciphertexts.first == null) {
            val downloaded = downloadAttachmentCiphertext(
                message.messageId, attachment.attachmentId, attachment.plaintextBytes.toInt() + 33,
                attachment.ciphertextSha256, onProgress, isCancelled,
            )
            val plaintext = EncryptedChatCodec.openAttachment(
                downloaded, attachment, message.channelId, message.membershipEpoch,
            )
            ciphertexts = downloaded to ciphertexts.second
            EncryptedSignalProtocolStore.open(app).use {
                it.cacheChatAttachment(
                    message.messageId.toString(),
                    EncryptedChatCodec.packAttachmentCiphertexts(ciphertexts.first, ciphertexts.second),
                )
            }
            partialAttachmentFile(message.messageId, attachment.attachmentId).delete()
            return plaintext
        }
        return EncryptedChatCodec.openAttachment(
            requireNotNull(ciphertexts.first), attachment, message.channelId, message.membershipEpoch,
        )
    }

    fun thumbnailData(
        message: ChatMessage,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ): ByteArray {
        val thumbnail = requireNotNull(message.attachment?.thumbnail)
        val cached = EncryptedSignalProtocolStore.open(app).use {
            it.chatRecord(message.messageId.toString())?.attachmentCiphertext
        }
        var ciphertexts = cached?.let(EncryptedChatCodec::unpackAttachmentCiphertexts) ?: (null to null)
        if (ciphertexts.second == null) {
            val downloaded = downloadAttachmentCiphertext(
                message.messageId, thumbnail.thumbnailId, thumbnail.plaintextBytes + 33,
                thumbnail.ciphertextSha256, onProgress, isCancelled,
            )
            val plaintext = EncryptedChatCodec.openThumbnail(
                downloaded, thumbnail, message.channelId, message.membershipEpoch,
            )
            ciphertexts = ciphertexts.first to downloaded
            EncryptedSignalProtocolStore.open(app).use {
                it.cacheChatAttachment(
                    message.messageId.toString(),
                    EncryptedChatCodec.packAttachmentCiphertexts(ciphertexts.first, ciphertexts.second),
                )
            }
            partialAttachmentFile(message.messageId, thumbnail.thumbnailId).delete()
            return plaintext
        }
        return EncryptedChatCodec.openThumbnail(
            requireNotNull(ciphertexts.second), thumbnail, message.channelId, message.membershipEpoch,
        )
    }

    private fun downloadAttachmentCiphertext(
        messageId: UUID,
        objectId: UUID,
        expectedBytes: Int,
        expectedSha256: ByteArray,
        onProgress: ((ChatTransferProgress) -> Unit)?,
        isCancelled: () -> Boolean,
    ): ByteArray {
        require(expectedBytes in 1..EncryptedChatCodec.MAX_ATTACHMENT_BYTES + 64 && expectedSha256.size == 32)
        val partial = partialAttachmentFile(messageId, objectId)
        var ciphertext = if (partial.isFile) partial.readBytes() else byteArrayOf()
        if (ciphertext.size > expectedBytes) {
            partial.delete()
            ciphertext = byteArrayOf()
        }
        onProgress?.invoke(ChatTransferProgress(ciphertext.size.toLong(), expectedBytes.toLong()))
        while (ciphertext.size < expectedBytes) {
            if (isCancelled()) throw java.util.concurrent.CancellationException("Attachment download cancelled")
            val chunk = api.downloadChatAttachmentChunk(session, objectId.toString(), ciphertext.size)
            if (chunk.totalBytes != expectedBytes || !chunk.ciphertextSha256.contentEquals(expectedSha256) ||
                chunk.bytes.isEmpty() || ciphertext.size + chunk.bytes.size > expectedBytes
            ) {
                partial.delete()
                throw IllegalArgumentException("Attachment download integrity check failed")
            }
            ciphertext += chunk.bytes
            val temporary = java.io.File(partial.parentFile, "${partial.name}.tmp")
            temporary.writeBytes(ciphertext)
            require(temporary.renameTo(partial) || run { partial.delete(); temporary.renameTo(partial) })
            onProgress?.invoke(ChatTransferProgress(ciphertext.size.toLong(), expectedBytes.toLong()))
        }
        if (!java.security.MessageDigest.getInstance("SHA-256").digest(ciphertext).contentEquals(expectedSha256)) {
            partial.delete()
            throw IllegalArgumentException("Attachment download integrity check failed")
        }
        return ciphertext
    }

    private fun partialAttachmentFile(messageId: UUID, objectId: UUID): java.io.File {
        val directory = java.io.File(app.noBackupFilesDir, "chat-partials").apply { mkdirs() }
        prunePartialAttachments(directory)
        return java.io.File(directory, "${messageId.toString().lowercase()}-${objectId.toString().lowercase()}.bin")
    }

    private fun prunePartialAttachments(directory: java.io.File) {
        synchronized(partialAttachmentLock) {
            val staleBefore = System.currentTimeMillis() - 24 * 60 * 60 * 1_000L
            val entries = directory.listFiles()?.filter { it.isFile }?.sortedWith(
                compareBy<java.io.File> { it.lastModified() }.thenBy { it.name },
            ).orEmpty()
            entries.filter { it.lastModified() < staleBefore || it.name.endsWith(".tmp") }.forEach { it.delete() }
            var total = entries.filter { it.exists() }.sumOf { it.length() }
            entries.filter { it.exists() }.forEach { file ->
                if (total > MAX_PARTIAL_ATTACHMENT_BYTES) {
                    val size = file.length()
                    if (file.delete()) total -= size
                }
            }
        }
    }

    fun pendingSendCount(): Int = EncryptedSignalProtocolStore.open(app).use { it.chatOutbox().size }

    fun retryPending(channels: List<ChannelSummary>): Int {
        val pending = EncryptedSignalProtocolStore.open(app).use { store ->
            store.chatOutbox().mapNotNull(::pendingFromRecord)
        }
        var delivered = 0
        pending.forEach { item ->
            val channel = channels.firstOrNull {
                it.channelId.equals(item.event.channelId.toString(), true)
            } ?: return@forEach
            if (channel.membershipEpoch != item.event.membershipEpoch) {
                // Linking or revoking a device rotates the membership epoch.
                // An unresolved event from the old epoch must never discover
                // the newly authorized device as a recipient.
                EncryptedSignalProtocolStore.open(app).use {
                    it.markChatOutbox(
                        item.event.eventId.toString(), "failed", "membership_epoch_changed",
                    )
                }
                return@forEach
            }
            runCatching { deliver(item, channel) }
                .onSuccess { delivered += 1 }
                .onFailure {
                    EncryptedSignalProtocolStore.open(app).use { store ->
                        store.markChatOutbox(item.event.eventId.toString(), "failed", "delivery_failed")
                    }
                }
        }
        return delivered
    }

    fun sendReceipt(kind: ChatEventKind, messageId: UUID, channel: ChannelSummary): ChatEvent {
        require(kind == ChatEventKind.DELIVERED || kind == ChatEventKind.READ || kind == ChatEventKind.PLAYED)
        return sendMutation(kind, messageId, "", channel)
    }

    fun sendReaction(value: String, messageId: UUID, channel: ChannelSummary): ChatEvent =
        sendMutation(ChatEventKind.REACTION, messageId, value, channel)

    fun removeReaction(messageId: UUID, channel: ChannelSummary): ChatEvent =
        sendMutation(ChatEventKind.REMOVE_REACTION, messageId, "", channel)

    fun editMessage(value: String, messageId: UUID, channel: ChannelSummary): ChatEvent =
        sendMutation(ChatEventKind.EDIT, messageId, value, channel)

    fun deleteMessage(messageId: UUID, channel: ChannelSummary): ChatEvent =
        sendMutation(ChatEventKind.DELETE, messageId, "", channel)

    fun setPinned(pinned: Boolean, messageId: UUID, channel: ChannelSummary): ChatEvent =
        sendMutation(if (pinned) ChatEventKind.PIN else ChatEventKind.UNPIN, messageId, "", channel)

    private fun send(
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment?,
        attachmentCiphertext: ByteArray?,
        channel: ChannelSummary,
        replyTo: UUID? = null,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ): ChatMessage {
        val message = ChatMessage(
            UUID.randomUUID(), UUID.fromString(channel.channelId), channel.membershipEpoch, Instant.now(),
            session.aci.lowercase(), session.deviceId, kind, text.trim(), attachment,
        )
        enqueue(ChatEvent.message(message, replyTo), attachmentCiphertext, channel, onProgress, isCancelled)
        return message
    }

    private fun sendMutation(
        kind: ChatEventKind,
        target: UUID,
        value: String,
        channel: ChannelSummary,
    ): ChatEvent {
        val event = ChatEvent(
            UUID.randomUUID(), UUID.fromString(channel.channelId), channel.membershipEpoch, Instant.now(),
            session.aci.lowercase(), session.deviceId, kind, targetMessageId = target, value = value,
        )
        enqueue(event, null, channel)
        return event
    }

    private fun enqueue(
        event: ChatEvent,
        attachmentCiphertext: ByteArray?,
        channel: ChannelSummary,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ) {
        val plaintext = EncryptedChatCodec.encodeEvent(event)
        val expiresAt = event.sentAt.plusSeconds(channel.retentionDays * 86_400L)
        val unresolvedRecipients = encodeRecipients(emptyList())
        // Commit local encrypted state before recipient discovery or any
        // network operation so an offline send survives process death.
        save(event, plaintext, channel.retentionDays, attachmentCiphertext)
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.putChatOutbox(
                EncryptedChatOutboxRecord(
                    event.eventId.toString(), event.channelId.toString(), event.membershipEpoch,
                    event.senderAci, event.senderDeviceId, event.sentAt.toEpochMilli(), expiresAt.toEpochMilli(),
                    plaintext, unresolvedRecipients, "queued", 0, null,
                ),
            )
        }
        val pending = PendingChatSend(event, emptyList(), expiresAt)
        try {
            deliver(pending, channel, onProgress, isCancelled)
        } catch (error: Throwable) {
            EncryptedSignalProtocolStore.open(app).use { store ->
                if (error is java.util.concurrent.CancellationException) {
                    store.cancelChatSend(event.eventId.toString())
                } else {
                    store.markChatOutbox(event.eventId.toString(), "failed", "delivery_failed")
                }
            }
            throw error
        }
    }

    private fun deliver(
        unresolved: PendingChatSend,
        channel: ChannelSummary,
        onProgress: ((ChatTransferProgress) -> Unit)? = null,
        isCancelled: () -> Boolean = { false },
    ) {
        require(unresolved.event.channelId.toString().equals(channel.channelId, true))
        require(unresolved.event.membershipEpoch == channel.membershipEpoch)
        if (consumeInjectedDeliveryFailure()) {
            throw java.io.IOException("Injected delivery interruption")
        }
        var item = unresolved
        if (item.recipients.isEmpty()) {
            val plaintext = EncryptedChatCodec.encodeEvent(item.event)
            val recipients = api.channelDevices(session, channel.channelId)
                .filterNot { it.aci == session.aci && it.deviceId == session.deviceId }
                .map { ChatRecipient(it.aci, it.deviceId, crypto.encryptDataFor(it, plaintext)) }
            if (recipients.isEmpty()) {
                EncryptedSignalProtocolStore.open(app).use { it.removeChatOutbox(item.event.eventId.toString()) }
                return
            }
            val emptyRecipients = encodeRecipients(emptyList())
            val encodedRecipients = encodeRecipients(recipients)
            EncryptedSignalProtocolStore.open(app).use {
                it.resolveChatOutboxRecipients(item.event.eventId.toString(), emptyRecipients, encodedRecipients)
            }
            item = item.copy(recipients = recipients)
        }
        EncryptedSignalProtocolStore.open(app).use { it.markChatOutbox(item.event.eventId.toString(), "sending") }
        item.event.message?.attachment?.let { attachment ->
            val cached = EncryptedSignalProtocolStore.open(app).use {
                it.chatRecord(item.event.eventId.toString())?.attachmentCiphertext
            }
            if (cached != null) {
                val ciphertexts = EncryptedChatCodec.unpackAttachmentCiphertexts(cached)
                val primary = requireNotNull(ciphertexts.first)
                val preview = ciphertexts.second
                val totalBytes = primary.size.toLong() + (preview?.size?.toLong() ?: 0L)
                api.uploadChatAttachment(
                    session, attachment.attachmentId.toString(), item.event.channelId.toString(),
                    channel.membershipEpoch, primary, attachment.ciphertextSha256,
                    onProgress = { onProgress?.invoke(ChatTransferProgress(it.completedBytes, totalBytes)) },
                    isCancelled = isCancelled,
                )
                attachment.thumbnail?.let { thumbnail ->
                    api.uploadChatAttachment(
                        session, thumbnail.thumbnailId.toString(), item.event.channelId.toString(),
                        channel.membershipEpoch, requireNotNull(preview), thumbnail.ciphertextSha256,
                        onProgress = {
                            onProgress?.invoke(ChatTransferProgress(primary.size + it.completedBytes, totalBytes))
                        },
                        isCancelled = isCancelled,
                    )
                }
            }
        }
        api.enqueueChat(
            session, item.event.eventId.toString(), item.event.channelId.toString(),
            channel.membershipEpoch, item.recipients, item.expiresAt,
        )
        EncryptedSignalProtocolStore.open(app).use { it.removeChatOutbox(item.event.eventId.toString()) }
    }

    @Synchronized
    private fun consumeInjectedDeliveryFailure(): Boolean {
        if (remainingInjectedDeliveryFailures == 0) return false
        remainingInjectedDeliveryFailures -= 1
        return true
    }

    private fun save(event: ChatEvent, payload: ByteArray, retentionDays: Int, attachmentCiphertext: ByteArray?) {
        val expiresAt = event.sentAt.plusSeconds(retentionDays * 86_400L).toEpochMilli()
        EncryptedSignalProtocolStore.open(app).use { store ->
            event.message?.let { message ->
                store.putChatRecord(
                    EncryptedChatRecord(
                        message.messageId.toString(), message.channelId.toString(), message.senderAci,
                        message.senderDeviceId, message.sentAt.toEpochMilli(), expiresAt,
                        payload, attachmentCiphertext,
                    ),
                )
            }
            store.putChatEvent(
                EncryptedChatEventRecord(
                    event.eventId.toString(), event.channelId.toString(), event.senderAci,
                    event.senderDeviceId, event.sentAt.toEpochMilli(), expiresAt, payload,
                ),
            )
        }
    }

    private data class PendingChatSend(
        val event: ChatEvent,
        val recipients: List<ChatRecipient>,
        val expiresAt: Instant,
    )

    private fun pendingFromRecord(record: EncryptedChatOutboxRecord): PendingChatSend? = runCatching {
        val event = EncryptedChatCodec.decodeEventOrLegacyMessage(
            record.payload, record.senderAci, record.senderDeviceId,
        )
        require(event.eventId.toString().equals(record.eventId, true))
        PendingChatSend(event, decodeRecipients(record.recipients), Instant.ofEpochMilli(record.expiresAtMs))
    }.getOrNull()

    private fun encodeRecipients(recipients: List<ChatRecipient>): ByteArray {
        require(recipients.size <= 128)
        val size = 4 + recipients.sumOf { 16 + 4 + 4 + it.envelope.size }
        return ByteBuffer.allocate(size).apply {
            putInt(recipients.size)
            recipients.forEach { recipient ->
                val aci = UUID.fromString(recipient.aci)
                putLong(aci.mostSignificantBits).putLong(aci.leastSignificantBits)
                putInt(recipient.deviceId).putInt(recipient.envelope.size).put(recipient.envelope)
            }
        }.array()
    }

    private fun decodeRecipients(bytes: ByteArray): List<ChatRecipient> {
        val buffer = ByteBuffer.wrap(bytes)
        require(buffer.remaining() >= 4)
        val count = buffer.int
        require(count in 0..128)
        val recipients = List(count) {
            require(buffer.remaining() >= 24)
            val aci = UUID(buffer.long, buffer.long).toString()
            val deviceId = buffer.int
            val length = buffer.int
            require(deviceId in 1..2 && length in 1..131_072 && buffer.remaining() >= length)
            ChatRecipient(aci, deviceId, ByteArray(length).also(buffer::get))
        }
        require(!buffer.hasRemaining())
        return recipients
    }

    private companion object {
        const val MAX_PARTIAL_ATTACHMENT_BYTES = 100L * 1_024 * 1_024
        val partialAttachmentLock = Any()
    }
}
