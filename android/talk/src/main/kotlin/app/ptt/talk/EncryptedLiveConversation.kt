package app.ptt.talk

import java.nio.ByteBuffer
import java.time.Instant
import java.util.UUID

internal enum class EncryptedLiveSignalKind(val wire: Byte) {
    TYPING_STARTED(1),
    TYPING_STOPPED(2),
}

/**
 * An encrypted, short-lived conversation signal. These values travel inside
 * the existing pairwise Signal envelope, are never written to chat history,
 * and expire before they can become meaningful historical metadata.
 */
internal data class EncryptedLiveSignal(
    val signalId: UUID,
    val channelId: UUID,
    val membershipEpoch: Int,
    val sentAt: Instant,
    val expiresAt: Instant,
    val kind: EncryptedLiveSignalKind,
    val threadRootId: UUID? = null,
)

internal object EncryptedLiveSignalCodec {
    private val MAGIC = "PTTI".encodeToByteArray()
    private val ZERO_UUID = UUID(0, 0)
    private const val WIRE_BYTES = 74
    const val MAX_TTL_SECONDS = 30L

    fun encode(signal: EncryptedLiveSignal): ByteArray {
        require(signal.signalId != ZERO_UUID && signal.channelId != ZERO_UUID)
        require(signal.membershipEpoch > 0)
        require(signal.expiresAt.isAfter(signal.sentAt))
        require(signal.expiresAt <= signal.sentAt.plusSeconds(MAX_TTL_SECONDS))
        return ByteBuffer.allocate(WIRE_BYTES).apply {
            put(MAGIC).put(1).put(signal.kind.wire)
            putUuid(signal.signalId).putUuid(signal.channelId)
            putInt(signal.membershipEpoch)
            putLong(signal.sentAt.toEpochMilli()).putLong(signal.expiresAt.toEpochMilli())
            putUuid(signal.threadRootId ?: ZERO_UUID)
        }.array()
    }

    fun decode(bytes: ByteArray): EncryptedLiveSignal {
        require(bytes.size == WIRE_BYTES)
        val buffer = ByteBuffer.wrap(bytes)
        require(ByteArray(4).also(buffer::get).contentEquals(MAGIC) && buffer.get().toInt() == 1)
        val kindWire = buffer.get()
        val kind = EncryptedLiveSignalKind.entries.firstOrNull { it.wire == kindWire }
            ?: error("invalid live signal kind")
        val signal = EncryptedLiveSignal(
            signalId = buffer.uuid(),
            channelId = buffer.uuid(),
            membershipEpoch = buffer.int,
            sentAt = Instant.ofEpochMilli(buffer.long),
            expiresAt = Instant.ofEpochMilli(buffer.long),
            kind = kind,
            threadRootId = buffer.uuid().let { if (it == ZERO_UUID) null else it },
        )
        require(!buffer.hasRemaining())
        require(encode(signal).contentEquals(bytes))
        return signal
    }

    fun isLiveSignal(bytes: ByteArray): Boolean =
        bytes.size >= MAGIC.size && bytes.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)

    private fun ByteBuffer.putUuid(value: UUID): ByteBuffer =
        putLong(value.mostSignificantBits).putLong(value.leastSignificantBits)

    private fun ByteBuffer.uuid(): UUID = UUID(long, long)
}
