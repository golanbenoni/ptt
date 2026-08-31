package app.ptt.media

import java.io.Closeable

/** Transport for fixed, end-to-end encrypted production media datagrams. */
interface MediaRelay : Closeable {
    fun send(packet: ByteArray)

    fun requestFloor(
        requestToken: String,
        membershipEpoch: Int,
        requestedTotMs: Int,
        sos: Boolean,
    ): MediaFloorGrant? = null
}

data class MediaFloorGrant(
    val granted: Boolean,
    val requestToken: String,
    val grantedTotMs: Int,
    val reason: String?,
)

class MediaFloorControlException(val code: String) : Exception(code)
