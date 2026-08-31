package app.ptt.talk

import android.content.Context
import app.ptt.crypto.persistence.EncryptedChatRecord
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.time.Instant
import java.util.UUID

internal class EncryptedChatClient(context: Context, private val session: DeviceSession) {
    private val app = context.applicationContext
    private val api = ControlApi(session.serverUrl)
    private val crypto = PersistentPairwiseCrypto(app, session)

    fun messages(channelId: String): List<ChatMessage> =
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.chatRecords(channelId).mapNotNull { record ->
                runCatching { EncryptedChatCodec.decode(record.payload, record.senderAci, record.senderDeviceId) }.getOrNull()
            }
        }

    fun sendText(text: String, channel: ChannelSummary): ChatMessage =
        send(ChatContentKind.TEXT, text, null, null, channel)

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
        api.uploadChatAttachment(
            session, attachmentId.toString(), channel.channelId, channel.membershipEpoch,
            sealed.first, sealed.third,
        )
        return send(kind, caption, attachment, sealed.first, channel)
    }

    fun poll(channels: List<ChannelSummary>): Int {
        val items = api.chatItems(session)
        if (items.isEmpty()) return 0
        val acknowledged = mutableListOf<String>()
        var accepted = 0
        items.forEach { item ->
            val channel = channels.firstOrNull { it.channelId.equals(item.channelId, ignoreCase = true) }
            if (channel == null || channel.membershipEpoch != item.membershipEpoch) {
                acknowledged += item.itemId
                return@forEach
            }
            runCatching {
                val devices = api.channelDevices(session, channel.channelId)
                val opened = crypto.decryptDataEnvelope(item.envelope, devices)
                val message = EncryptedChatCodec.decode(opened.plaintext, opened.senderAci, opened.senderDeviceId)
                require(message.messageId.toString().equals(item.messageId, ignoreCase = true))
                require(message.channelId.toString().equals(item.channelId, ignoreCase = true))
                require(message.membershipEpoch == item.membershipEpoch)
                val now = Instant.now()
                require(!message.sentAt.isAfter(now.plusSeconds(300)))
                require(!message.sentAt.isBefore(now.minusSeconds(channel.retentionDays * 86_400L + 86_400L)))
                save(message, EncryptedChatCodec.encode(message), channel.retentionDays, null)
                acknowledged += item.itemId
                accepted += 1
            }
        }
        if (acknowledged.isNotEmpty()) api.acknowledgeChat(session, acknowledged)
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

    private fun send(
        kind: ChatContentKind,
        text: String,
        attachment: ChatAttachment?,
        attachmentCiphertext: ByteArray?,
        channel: ChannelSummary,
    ): ChatMessage {
        val message = ChatMessage(
            UUID.randomUUID(), UUID.fromString(channel.channelId), channel.membershipEpoch, Instant.now(),
            session.aci, session.deviceId, kind, text.trim(), attachment,
        )
        val plaintext = EncryptedChatCodec.encode(message)
        val recipients = api.channelDevices(session, channel.channelId)
            .filterNot { it.aci == session.aci && it.deviceId == session.deviceId }
            .map { ChatRecipient(it.aci, it.deviceId, crypto.encryptFor(it, plaintext)) }
        val expiresAt = message.sentAt.plusSeconds(channel.retentionDays * 86_400L)
        if (recipients.isNotEmpty()) {
            api.enqueueChat(
                session, message.messageId.toString(), channel.channelId, channel.membershipEpoch,
                recipients, expiresAt,
            )
        }
        save(message, plaintext, channel.retentionDays, attachmentCiphertext)
        return message
    }

    private fun save(message: ChatMessage, payload: ByteArray, retentionDays: Int, attachmentCiphertext: ByteArray?) {
        EncryptedSignalProtocolStore.open(app).use { store ->
            store.putChatRecord(
                EncryptedChatRecord(
                    message.messageId.toString(), message.channelId.toString(), message.senderAci,
                    message.senderDeviceId, message.sentAt.toEpochMilli(),
                    message.sentAt.plusSeconds(retentionDays * 86_400L).toEpochMilli(),
                    payload, attachmentCiphertext,
                ),
            )
        }
    }
}
