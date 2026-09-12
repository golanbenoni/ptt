package app.ptt.media

import java.io.Closeable
import java.io.IOException

/** Transport for fixed, end-to-end encrypted production media datagrams. */
interface MediaRelay : Closeable {
    fun send(packet: ByteArray)

    fun requestFloor(
        requestToken: String,
        membershipEpoch: Int,
        requestedTotMs: Int,
        sos: Boolean,
    ): MediaFloorGrant? = null

    /** Returns null when this transport cannot order release behind queued media. */
    fun releaseFloor(requestToken: String): Boolean? = null
}

data class MediaFloorGrant(
    val granted: Boolean,
    val requestToken: String,
    val grantedTotMs: Int,
    val reason: String?,
)

class MediaFloorControlException(val code: String) : Exception(code)

/** A relay transport stopped carrying authenticated ciphertext and may be re-established. */
class MediaRelayConnectionException(message: String, cause: Throwable? = null) :
    IOException(message, cause)
