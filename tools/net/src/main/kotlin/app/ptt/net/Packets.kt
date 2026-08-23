package app.ptt.net

import java.nio.ByteBuffer
import java.util.UUID

object Packets {
    const val BIND: Byte = 0xB1.toByte()
    const val KEY: Byte = 0x4B
    const val FRAME: Byte = 0xF1.toByte()

    fun bind(channel: UUID, aci: UUID): ByteArray {
        val buf = ByteBuffer.allocate(1 + 16 + 16)
        buf.put(BIND)
        putUuid(buf, channel)
        putUuid(buf, aci)
        return buf.array()
    }

    fun key(channel: UUID, talkId: UUID, demux: Int, frames: Int, wrappedKey: ByteArray): ByteArray {
        val buf = ByteBuffer.allocate(1 + 16 + 16 + 4 + 4 + wrappedKey.size)
        buf.put(KEY)
        putUuid(buf, channel)
        putUuid(buf, talkId)
        buf.putInt(demux)
        buf.putInt(frames)
        buf.put(wrappedKey)
        return buf.array()
    }

    fun frame(channel: UUID, talkId: UUID, demux: Int, payload: ByteArray): ByteArray {
        val buf = ByteBuffer.allocate(1 + 16 + 16 + 4 + payload.size)
        buf.put(FRAME)
        putUuid(buf, channel)
        putUuid(buf, talkId)
        buf.putInt(demux)
        buf.put(payload)
        return buf.array()
    }

    fun type(p: ByteArray): Byte = p[0]

    fun channel(p: ByteArray): UUID = uuidAt(p, 1)

    fun bindAci(p: ByteArray): UUID = uuidAt(p, 17)

    fun talkId(p: ByteArray): UUID = uuidAt(p, 17)

    fun demux(p: ByteArray): Int = ByteBuffer.wrap(p, 33, 4).int

    fun keyFrameCount(p: ByteArray): Int = ByteBuffer.wrap(p, 37, 4).int

    fun keyWrapped(p: ByteArray): ByteArray = p.copyOfRange(41, p.size)

    fun framePayload(p: ByteArray): ByteArray = p.copyOfRange(37, p.size)

    fun putUuid(buf: ByteBuffer, uuid: UUID) {
        buf.putLong(uuid.mostSignificantBits)
        buf.putLong(uuid.leastSignificantBits)
    }

    fun uuidAt(p: ByteArray, off: Int): UUID {
        val b = ByteBuffer.wrap(p, off, 16)
        return UUID(b.long, b.long)
    }
}
