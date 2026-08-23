package app.ptt.crypto

import java.nio.ByteBuffer
import java.util.UUID

/**
 * Versioned TalkStart blob. PR3 replaces this with protobuf; the field set is frozen.
 *
 * Layout:
 *   magic "TS01"
 *   requestToken: u16be len + bytes
 *   talkId: 16
 *   totMs: u32be
 *   kid: u64be
 *   senderDemux: u32be
 *   channelId: 16
 *   epoch: u32be
 *   baseKey: u16be len + bytes
 *   suite: u32be  (0x0004 = AES_128_GCM_SHA256_128)
 *   graceMs: u32be
 */
object TalkStartCodec {
    private val MAGIC = byteArrayOf('T'.code.toByte(), 'S'.code.toByte(), '0'.code.toByte(), '1'.code.toByte())
    const val SUITE_AES_128_GCM = 0x0004
    const val SUITE_AES_256_GCM = 0x0005

    fun encode(decision: FloorDecision, epoch: MediaEpoch): ByteArray {
        require(decision.talkId == epoch.talkId) { "talkId mismatch" }
        require(decision.mediaEpochKid == epoch.kid) { "kid mismatch" }
        require(decision.senderDemux == epoch.senderDemux) { "demux mismatch" }
        require(decision.requestToken.size <= 0xffff) { "request token too long" }
        require(epoch.baseKey.size == keySize(epoch.suite)) { "key length does not match suite" }
        val buf = ByteBuffer.allocate(4 + 2 + decision.requestToken.size + 16 + 4 + 8 + 4 + 16 + 4 + 2 + epoch.baseKey.size + 4 + 4)
        buf.put(MAGIC)
        buf.putShort(decision.requestToken.size.toShort())
        buf.put(decision.requestToken)
        putUuid(buf, decision.talkId)
        buf.putInt(decision.totMs)
        buf.putLong(decision.mediaEpochKid)
        buf.putInt(decision.senderDemux)
        putUuid(buf, epoch.channelId.uuid)
        buf.putInt(epoch.epoch)
        buf.putShort(epoch.baseKey.size.toShort())
        buf.put(epoch.baseKey)
        buf.putInt(when (epoch.suite) {
            CipherSuite.AES_128_GCM_SHA256_128 -> SUITE_AES_128_GCM
            CipherSuite.AES_256_GCM_SHA512_128 -> SUITE_AES_256_GCM
        })
        buf.putInt(epoch.graceMs)
        require(buf.remaining() == 0)
        return buf.array()
    }

    fun decode(bytes: ByteArray): Triple<FloorDecision, MediaEpoch, ChannelId> {
        val buf = ByteBuffer.wrap(bytes)
        requireRemaining(buf, 6, "TalkStart header")
        val magic = ByteArray(4)
        buf.get(magic)
        require(magic.contentEquals(MAGIC)) { "bad TalkStart magic" }
        val tokLen = buf.short.toInt() and 0xffff
        requireRemaining(buf, tokLen + FIXED_AFTER_TOKEN_BYTES, "TalkStart token/body")
        val token = ByteArray(tokLen)
        buf.get(token)
        val talkId = getUuid(buf)
        val totMs = buf.int
        val kid = buf.long
        val demux = buf.int
        val channel = ChannelId(getUuid(buf))
        val epochN = buf.int
        val keyLen = buf.short.toInt() and 0xffff
        requireRemaining(buf, keyLen + 8, "TalkStart key/trailer")
        val key = ByteArray(keyLen)
        buf.get(key)
        val suite = when (buf.int) {
            SUITE_AES_128_GCM -> CipherSuite.AES_128_GCM_SHA256_128
            SUITE_AES_256_GCM -> CipherSuite.AES_256_GCM_SHA512_128
            else -> throw IllegalArgumentException("unsupported TalkStart cipher suite")
        }
        require(keyLen == keySize(suite)) { "key length does not match suite" }
        val grace = buf.int
        require(!buf.hasRemaining()) { "trailing TalkStart bytes" }
        val decision = FloorDecision(token, talkId, totMs, kid, demux)
        val epoch = MediaEpoch(talkId, epochN, kid, key, suite, grace, demux, channel)
        return Triple(decision, epoch, channel)
    }

    internal fun putUuid(buf: ByteBuffer, uuid: UUID) {
        buf.putLong(uuid.mostSignificantBits)
        buf.putLong(uuid.leastSignificantBits)
    }

    internal fun getUuid(buf: ByteBuffer): UUID = UUID(buf.long, buf.long)

    private fun keySize(suite: CipherSuite): Int =
        when (suite) {
            CipherSuite.AES_128_GCM_SHA256_128 -> 16
            CipherSuite.AES_256_GCM_SHA512_128 -> 32
        }

    private fun requireRemaining(buf: ByteBuffer, count: Int, field: String) {
        require(count >= 0 && buf.remaining() >= count) { "truncated $field" }
    }

    // talkId + totMs + kid + demux + channelId + epoch + keyLen
    private const val FIXED_AFTER_TOKEN_BYTES = 16 + 4 + 8 + 4 + 16 + 4 + 2
}
