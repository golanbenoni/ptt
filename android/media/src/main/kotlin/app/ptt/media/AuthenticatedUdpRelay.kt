package app.ptt.media

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.URI
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import kotlin.concurrent.thread

/** One authenticated UDP tuple bound to a relay lease for a single channel. */
class AuthenticatedUdpRelay private constructor(
    private val socket: DatagramSocket,
    private val receiveThread: Thread,
) : MediaRelay {
    @Synchronized
    override fun send(packet: ByteArray) {
        check(!socket.isClosed) { "relay connection is closed" }
        require(packet.size == MEDIA_DATAGRAM_BYTES) { "relay accepts only production media datagrams" }
        socket.send(DatagramPacket(packet, packet.size))
    }

    override fun close() {
        socket.close()
        receiveThread.interrupt()
        if (Thread.currentThread() !== receiveThread) receiveThread.join(1_000)
    }

    companion object {
        fun connect(
            publicAddress: String,
            ticket: String,
            expectedSenderDemux: Long,
            onMedia: (ByteArray) -> Unit,
            onError: (Throwable) -> Unit = {},
        ): AuthenticatedUdpRelay {
            require(ticket.isNotBlank() && ticket.length <= 4_096) { "invalid relay ticket" }
            require(expectedSenderDemux in 1..0xffff_ffffL) { "invalid sender demux" }
            val endpoint = parseEndpoint(publicAddress)
            val socket = DatagramSocket()
            try {
                socket.connect(endpoint)
                socket.soTimeout = 3_000
                val bind = "PTTB".encodeToByteArray() + ticket.toByteArray(StandardCharsets.US_ASCII)
                socket.send(DatagramPacket(bind, bind.size))
                val ackBytes = ByteArray(8)
                val ack = DatagramPacket(ackBytes, ackBytes.size)
                socket.receive(ack)
                require(ack.length == 8 && ackBytes.copyOfRange(0, 4).contentEquals("PTTA".encodeToByteArray())) {
                    "relay binding acknowledgement is invalid"
                }
                val acknowledged = ByteBuffer.wrap(ackBytes, 4, 4).int.toLong() and 0xffff_ffffL
                require(acknowledged == expectedSenderDemux) { "relay acknowledged the wrong sender demux" }
                socket.soTimeout = 1_000
            } catch (error: Throwable) {
                socket.close()
                throw error
            }
            lateinit var result: AuthenticatedUdpRelay
            val receiver =
                thread(start = false, name = "ptt-udp-relay-receive", priority = Thread.NORM_PRIORITY + 1) {
                    val storage = ByteArray(MEDIA_DATAGRAM_BYTES + 1)
                    while (!socket.isClosed && !Thread.currentThread().isInterrupted) {
                        val packet = DatagramPacket(storage, storage.size)
                        try {
                            socket.receive(packet)
                            if (packet.length == MEDIA_DATAGRAM_BYTES) {
                                onMedia(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
                            }
                        } catch (_: SocketTimeoutException) {
                            // Periodically wake so close/interruption is observed.
                        } catch (error: Throwable) {
                            if (!socket.isClosed) onError(error)
                            break
                        }
                    }
                }
            result = AuthenticatedUdpRelay(socket, receiver)
            receiver.start()
            return result
        }

        internal fun parseEndpoint(publicAddress: String): InetSocketAddress {
            val value = publicAddress.trim()
            require(value.isNotEmpty()) { "relay address is required" }
            val uri = URI.create(if (value.contains("://")) value else "udp://$value")
            require(uri.scheme == "udp" && uri.host != null && uri.port in 1..65_535) {
                "relay address must be host:port or udp://host:port"
            }
            return InetSocketAddress(uri.host, uri.port)
        }
    }
}
