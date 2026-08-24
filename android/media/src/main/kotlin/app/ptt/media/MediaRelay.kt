package app.ptt.media

import java.io.Closeable

/** Transport for fixed, end-to-end encrypted production media datagrams. */
interface MediaRelay : Closeable {
    fun send(packet: ByteArray)
}
