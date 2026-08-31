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
import org.signal.libsignal.protocol.NoSessionException

internal class EncryptedChatClient(context: Context, private val session: DeviceSession) {
    private val app = context.applicationContext
    private val api = ControlApi(session.serverUrl)
    private val crypto = PersistentPairwiseCrypto(app, session)

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

    private fun draftKey(channelId: String): String =
        "chat-draft-v1-${UUID.fromString(channelId).toString().lowercase()}"

    fun conversation(channelId: String): List<ChatConversationMessage> =
        EncryptedSignalProtocolStore.open(app).use { store ->
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
                if (!item.message.senderAci.equals(session.aci, true)) return@map item
                val state = when (pending[item.message.messageId.toString()]) {
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
                item.copy(sendState = state)
            }
        }

    fun unreadCount(channelId: String): Int = conversation(channelId).count { it.isUnread }

    fun sendText(text: String, channel: ChannelSummary, replyTo: UUID? = null): ChatMessage =
        send(ChatContentKind.TEXT, text, null, null, channel, replyTo)

    fun sendAttachment(
        data: ByteArray,
        fileName: String,
        mimeType: String,
        kind: ChatContentKind,
        durationMs: Int = 0,
        caption: String = "",
        channel: ChannelSummary,
    ): ChatMessage {
        require(kind != ChatContentKind.TEXT)
        val channelId = UUID.fromString(channel.channelId)
        val attachmentId = UUID.randomUUID()
        val sealed = EncryptedChatCodec.sealAttachment(data, attachmentId, channelId, channel.membershipEpoch)
        val attachment = ChatAttachment(
            attachmentId,
            EncryptedChatCodec.boundedUtf8(fileName, 255).ifBlank { "Attachment" },
            EncryptedChatCodec.boundedUtf8(mimeType, 127).ifBlank { "application/octet-stream" },
            data.size.toLong(), durationMs,
            sealed.second, sealed.third,
        )
        return send(kind, caption, attachment, sealed.first, channel)
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
            } catch (_: NoSessionException) {
                // Keep an overtaking regular message in the mailbox until its
                // prekey message has established the domain-separated session.
                return@forEach
            } catch (_: DuplicateMessageException) {
                // The server queue is at-least-once. Once libsignal proves the
                // ciphertext counter was already consumed, acknowledge the
                // queue item and continue with newer traffic.
                acknowledged += item.itemId
            }
        }
        if (acknowledged.isNotEmpty()) api.acknowledgeChat(session, acknowledged)
        deliveredReceipts.forEach { (messageId, channel) ->
            runCatching { sendReceipt(ChatEventKind.DELIVERED, messageId, channel) }
        }
        return accepted
    }

    fun attachmentData(message: ChatMessage): ByteArray {
        val attachment = requireNotNull(message.attachment)
        val cached = EncryptedSignalProtocolStore.open(app).use { it.chatRecord(message.messageId.toString())?.attachmentCiphertext }
        val ciphertext = cached ?: api.downloadChatAttachment(session, attachment.attachmentId.toString()).also { downloaded ->
            EncryptedSignalProtocolStore.open(app).use { it.cacheChatAttachment(message.messageId.toString(), downloaded) }
        }
        return EncryptedChatCodec.openAttachment(ciphertext, attachment, message.channelId, message.membershipEpoch)
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

    private fun send(
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment?,
        attachmentCiphertext: ByteArray?,
        channel: ChannelSummary,
        replyTo: UUID? = null,
    ): ChatMessage {
        val message = ChatMessage(
            UUID.randomUUID(), UUID.fromString(channel.channelId), channel.membershipEpoch, Instant.now(),
            session.aci.lowercase(), session.deviceId, kind, text.trim(), attachment,
        )
        enqueue(ChatEvent.message(message, replyTo), attachmentCiphertext, channel)
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

    private fun enqueue(event: ChatEvent, attachmentCiphertext: ByteArray?, channel: ChannelSummary) {
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
            deliver(pending, channel)
        } catch (error: Throwable) {
            EncryptedSignalProtocolStore.open(app).use { store ->
                store.markChatOutbox(event.eventId.toString(), "failed", "delivery_failed")
            }
            throw error
        }
    }

    private fun deliver(unresolved: PendingChatSend, channel: ChannelSummary) {
        require(unresolved.event.channelId.toString().equals(channel.channelId, true))
        require(unresolved.event.membershipEpoch == channel.membershipEpoch)
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
            val ciphertext = EncryptedSignalProtocolStore.open(app).use {
                it.chatRecord(item.event.eventId.toString())?.attachmentCiphertext
            }
            if (ciphertext != null) {
                api.uploadChatAttachment(
                    session, attachment.attachmentId.toString(), item.event.channelId.toString(),
                    channel.membershipEpoch, ciphertext, attachment.ciphertextSha256,
                )
            }
        }
        api.enqueueChat(
            session, item.event.eventId.toString(), item.event.channelId.toString(),
            channel.membershipEpoch, item.recipients, item.expiresAt,
        )
        EncryptedSignalProtocolStore.open(app).use { it.removeChatOutbox(item.event.eventId.toString()) }
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
}
