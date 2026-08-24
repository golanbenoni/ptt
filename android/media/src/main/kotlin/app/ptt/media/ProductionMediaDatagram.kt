package app.ptt.media

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

const val MEDIA_DATAGRAM_BYTES = 160
const val MEDIA_HEADER_BYTES = 20
const val MEDIA_HMAC_BYTES = 8
const val MEDIA_SFRAME_CAPACITY = MEDIA_DATAGRAM_BYTES - MEDIA_HEADER_BYTES - MEDIA_HMAC_BYTES
const val MEDIA_FIXED_PLAINTEXT_BYTES = 99
const val MEDIA_MAX_OPUS_PACKET_BYTES = MEDIA_FIXED_PLAINTEXT_BYTES - 1
const val MEDIA_FLAG_FEC = 0x01
const val MEDIA_FLAG_START = 0x02
const val MEDIA_FLAG_END = 0x04
const val MEDIA_FLAG_HMAC8 = 0x08

data class ProductionMediaHeader(
    val flags: Int,
    val senderDemux: Long,
    val sequence: Long,
    val timestampRtp: Long,
    val talkIdPrefix: ByteArray,
) {
    init {
        require(flags and MEDIA_FLAG_HMAC8 != 0) { "relay-authenticated media must set HMAC8" }
        require(flags and 0xf0 == 0) { "unknown media flags" }
        require(senderDemux in 1..UINT32_MAX) { "sender demux must be an unsigned nonzero 32-bit value" }
        require(sequence in 0..UINT32_MAX) { "sequence must be unsigned 32-bit" }
        require(timestampRtp in 0..UINT32_MAX) { "RTP timestamp must be unsigned 32-bit" }
        require(talkIdPrefix.size == 4) { "talk ID prefix must contain four bytes" }
    }
}

data class ReceivedProductionMedia(
    val header: ProductionMediaHeader,
    val sframe: ByteArray,
)

object ProductionMediaDatagram {
    fun encode(
        header: ProductionMediaHeader,
        sframe: ByteArray,
        demuxToken: ByteArray,
    ): ByteArray {
        require(demuxToken.size == 32) { "demux token must contain 32 bytes" }
        require(sframe.size == sframeCiphertextLength(sframe, MEDIA_FIXED_PLAINTEXT_BYTES)) {
            "SFrame must encrypt the fixed production voice envelope"
        }
        require(sframe.size <= MEDIA_SFRAME_CAPACITY) { "SFrame exceeds production datagram capacity" }
        return ByteArray(MEDIA_DATAGRAM_BYTES).also { output ->
            writeHeader(output, header)
            sframe.copyInto(output, MEDIA_HEADER_BYTES)
            val authenticated = output.size - MEDIA_HMAC_BYTES
            hmac8(demuxToken, output, authenticated).copyInto(output, authenticated)
        }
    }

    /**
     * Parses relay-forwarded media. The relay validates the sender-specific HMAC before fan-out;
     * receivers authenticate the routing fields again as RFC 9605 AAD.
     */
    fun decode(packet: ByteArray): ReceivedProductionMedia {
        require(packet.size == MEDIA_DATAGRAM_BYTES) { "production media datagram must contain 160 bytes" }
        val header = readHeader(packet)
        val padded = packet.copyOfRange(MEDIA_HEADER_BYTES, packet.size - MEDIA_HMAC_BYTES)
        val sframeLength = sframeCiphertextLength(padded, MEDIA_FIXED_PLAINTEXT_BYTES)
        require(sframeLength <= padded.size) { "truncated SFrame" }
        return ReceivedProductionMedia(header, padded.copyOf(sframeLength))
    }

    fun verifySenderAuthentication(packet: ByteArray, demuxToken: ByteArray): Boolean {
        if (packet.size != MEDIA_DATAGRAM_BYTES || demuxToken.size != 32) return false
        val authenticated = packet.size - MEDIA_HMAC_BYTES
        return MessageDigest.isEqual(
            hmac8(demuxToken, packet, authenticated),
            packet.copyOfRange(authenticated, packet.size),
        )
    }

    private fun writeHeader(output: ByteArray, header: ProductionMediaHeader) {
        val buffer = ByteBuffer.wrap(output)
        buffer.put(1)
        buffer.put(header.flags.toByte())
        buffer.putInt(header.senderDemux.toInt())
        buffer.putInt(header.sequence.toInt())
        buffer.putInt(header.timestampRtp.toInt())
        buffer.putShort(0)
        buffer.put(header.talkIdPrefix)
    }

    private fun readHeader(packet: ByteArray): ProductionMediaHeader {
        val buffer = ByteBuffer.wrap(packet)
        require(buffer.get().toInt() and 0xff == 1) { "unsupported media version" }
        val flags = buffer.get().toInt() and 0xff
        val senderDemux = buffer.int.toLong() and UINT32_MAX
        val sequence = buffer.int.toLong() and UINT32_MAX
        val timestamp = buffer.int.toLong() and UINT32_MAX
        require(buffer.short.toInt() and 0xffff == 0) { "unsupported media payload type" }
        val talkPrefix = ByteArray(4).also(buffer::get)
        return ProductionMediaHeader(flags, senderDemux, sequence, timestamp, talkPrefix)
    }

    private fun hmac8(key: ByteArray, bytes: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(bytes, 0, length)
        return mac.doFinal().copyOf(MEDIA_HMAC_BYTES)
    }
}

object ProductionVoicePayload {
    fun pack(opus: ByteArray): ByteArray {
        require(opus.isNotEmpty() && opus.size <= MEDIA_MAX_OPUS_PACKET_BYTES) {
            "Opus packet must contain 1..$MEDIA_MAX_OPUS_PACKET_BYTES bytes"
        }
        return ByteArray(MEDIA_FIXED_PLAINTEXT_BYTES).also {
            it[0] = opus.size.toByte()
            opus.copyInto(it, 1)
        }
    }

    fun unpack(plaintext: ByteArray): ByteArray {
        require(plaintext.size == MEDIA_FIXED_PLAINTEXT_BYTES) { "invalid voice envelope length" }
        val length = plaintext[0].toInt() and 0xff
        require(length in 1..MEDIA_MAX_OPUS_PACKET_BYTES) { "invalid Opus packet length" }
        require(plaintext.copyOfRange(1 + length, plaintext.size).all { it.toInt() == 0 }) {
            "voice envelope padding is not canonical"
        }
        return plaintext.copyOfRange(1, 1 + length)
    }
}

fun productionSFrameAad(channelId: UUID, talkId: UUID, senderDemux: Long): ByteArray {
    require(senderDemux in 1..UINT32_MAX) { "sender demux must be unsigned nonzero 32-bit" }
    return ByteBuffer.allocate(36)
        .putLong(channelId.mostSignificantBits)
        .putLong(channelId.leastSignificantBits)
        .putLong(talkId.mostSignificantBits)
        .putLong(talkId.leastSignificantBits)
        .putInt(senderDemux.toInt())
        .array()
}

fun talkIdPrefix(talkId: UUID): ByteArray =
    ByteBuffer.allocate(8).putLong(talkId.mostSignificantBits).array().copyOf(4)

private const val UINT32_MAX = 0xffff_ffffL
