package app.ptt.talk

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.UUID

private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean =
    if (this == null || other == null) this == null && other == null else contentEquals(other)

internal enum class EncryptedCallKeyMessageKind(val wire: Byte) {
    ANNOUNCEMENT(1), ACKNOWLEDGEMENT(2);

    companion object { fun fromWire(value: Byte) = entries.firstOrNull { it.wire == value } }
}

internal data class EncryptedCallKeyMessage(
    val messageId: UUID = UUID.randomUUID(),
    val channelId: UUID,
    val membershipEpoch: Int,
    val callId: UUID,
    val callEpoch: Int,
    val kind: EncryptedCallKeyMessageKind,
    val participantIdentity: String,
    val key: ByteArray?,
    val senderAci: String = "",
    val senderDeviceId: Int = 0,
) {
    override fun equals(other: Any?): Boolean = other is EncryptedCallKeyMessage &&
        messageId == other.messageId && channelId == other.channelId &&
        membershipEpoch == other.membershipEpoch && callId == other.callId &&
        callEpoch == other.callEpoch && kind == other.kind &&
        participantIdentity == other.participantIdentity && key.contentEqualsNullable(other.key) &&
        senderAci == other.senderAci && senderDeviceId == other.senderDeviceId

    override fun hashCode(): Int = 31 * messageId.hashCode() + (key?.contentHashCode() ?: 0)
}

internal enum class CallKeyMessageDisposition { PROCESS, DEFER_FUTURE_EPOCH, DISCARD }

/**
 * Roster updates and encrypted key envelopes use separate authenticated transports. A valid
 * next-epoch envelope can therefore arrive before the next authoritative call snapshot. Retain
 * it without installing it; stale and context-mismatched envelopes remain terminal.
 */
internal object CallKeyMessageAcceptancePolicy {
    fun decide(
        callMatches: Boolean,
        channelMatches: Boolean,
        membershipEpochMatches: Boolean,
        authorizedSender: Boolean,
        messageEpoch: Int,
        currentEpoch: Int,
    ): CallKeyMessageDisposition {
        if (!callMatches || !channelMatches || !membershipEpochMatches) {
            return CallKeyMessageDisposition.DISCARD
        }
        if (messageEpoch > currentEpoch) return CallKeyMessageDisposition.DEFER_FUTURE_EPOCH
        if (messageEpoch < currentEpoch || !authorizedSender) return CallKeyMessageDisposition.DISCARD
        return CallKeyMessageDisposition.PROCESS
    }
}

internal object EncryptedCallKeyCodec {
    private val magic = "PTTC".toByteArray(StandardCharsets.UTF_8)
    private const val VERSION: Byte = 1

    fun encode(message: EncryptedCallKeyMessage): ByteArray {
        val identity = message.participantIdentity.toByteArray(StandardCharsets.UTF_8)
        require(message.membershipEpoch > 0 && message.callEpoch > 0 && identity.size in 16..128)
        require(when (message.kind) {
            EncryptedCallKeyMessageKind.ANNOUNCEMENT -> message.key?.size == 32
            EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT -> message.key?.size == 16
        })
        return ByteBuffer.allocate(63 + identity.size + (message.key?.size ?: 0)).apply {
            put(magic); put(VERSION); put(message.kind.wire)
            putUuid(message.messageId); putUuid(message.channelId); putUuid(message.callId)
            putInt(message.membershipEpoch); putInt(message.callEpoch)
            put(identity.size.toByte()); put(identity); message.key?.let(::put)
        }.array()
    }

    fun decode(bytes: ByteArray, senderAci: String, senderDeviceId: Int): EncryptedCallKeyMessage {
        require(bytes.size >= 63 && bytes.copyOfRange(0, 4).contentEquals(magic) && bytes[4] == VERSION)
        require(senderDeviceId in 1..2)
        UUID.fromString(senderAci)
        val buffer = ByteBuffer.wrap(bytes)
        buffer.position(5)
        val kind = requireNotNull(EncryptedCallKeyMessageKind.fromWire(buffer.get()))
        val messageId = buffer.getUuid()
        val channelId = buffer.getUuid()
        val callId = buffer.getUuid()
        val membershipEpoch = buffer.int
        val callEpoch = buffer.int
        val identitySize = buffer.get().toInt() and 0xff
        require(identitySize in 16..128 && buffer.remaining() >= identitySize)
        val identityBytes = ByteArray(identitySize).also(buffer::get)
        val key = ByteArray(buffer.remaining()).also(buffer::get).takeIf(ByteArray::isNotEmpty)
        val message = EncryptedCallKeyMessage(
            messageId, channelId, membershipEpoch, callId, callEpoch, kind,
            identityBytes.toString(StandardCharsets.UTF_8), key, senderAci.lowercase(), senderDeviceId,
        )
        require(encode(message).contentEquals(bytes))
        return message
    }

    private fun ByteBuffer.putUuid(value: UUID) { putLong(value.mostSignificantBits); putLong(value.leastSignificantBits) }
    private fun ByteBuffer.getUuid() = UUID(long, long)
}

/** Device-encrypted durable inbox format for call coordination consumed across app components. */
internal object EncryptedCallKeyQueueCodec {
    private val magic = "PTTQ".toByteArray(StandardCharsets.UTF_8)
    private const val VERSION: Byte = 1
    const val MAX_MESSAGES = 128

    fun encode(messages: List<EncryptedCallKeyMessage>): ByteArray {
        require(messages.size <= MAX_MESSAGES)
        val rows = messages.map { message ->
            require(message.senderDeviceId in 1..2)
            UUID.fromString(message.senderAci)
            message to EncryptedCallKeyCodec.encode(message)
        }
        return ByteBuffer.allocate(7 + rows.sumOf { 19 + it.second.size }).apply {
            put(magic); put(VERSION); putShort(rows.size.toShort())
            rows.forEach { (message, body) ->
                val sender = UUID.fromString(message.senderAci)
                putLong(sender.mostSignificantBits); putLong(sender.leastSignificantBits)
                put(message.senderDeviceId.toByte()); putShort(body.size.toShort()); put(body)
            }
        }.array()
    }

    fun decode(bytes: ByteArray?): List<EncryptedCallKeyMessage> {
        if (bytes == null || bytes.isEmpty()) return emptyList()
        require(bytes.size >= 7 && bytes.copyOfRange(0, 4).contentEquals(magic) && bytes[4] == VERSION)
        val buffer = ByteBuffer.wrap(bytes).apply { position(5) }
        val count = buffer.short.toInt() and 0xffff
        require(count <= MAX_MESSAGES)
        val messages = buildList(count) {
            repeat(count) {
                require(buffer.remaining() >= 19)
                val sender = UUID(buffer.long, buffer.long).toString().lowercase()
                val deviceId = buffer.get().toInt() and 0xff
                val size = buffer.short.toInt() and 0xffff
                require(deviceId in 1..2 && size in 63..255 && buffer.remaining() >= size)
                val body = ByteArray(size).also(buffer::get)
                add(EncryptedCallKeyCodec.decode(body, sender, deviceId))
            }
        }
        require(!buffer.hasRemaining())
        return messages
    }
}
