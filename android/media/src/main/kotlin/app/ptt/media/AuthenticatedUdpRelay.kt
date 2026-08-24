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
            heartbeatIntervalMillis: Long = 5_000,
            heartbeatTimeoutMillis: Long = 3_000,
        ): AuthenticatedUdpRelay {
            require(ticket.isNotBlank() && ticket.length <= 4_096) { "invalid relay ticket" }
            require(expectedSenderDemux in 1..0xffff_ffffL) { "invalid sender demux" }
            require(heartbeatIntervalMillis > 0 && heartbeatTimeoutMillis > 0) { "invalid heartbeat timing" }
            val endpoint = parseEndpoint(publicAddress)
            val socket = DatagramSocket()
            val bind = "PTTB".encodeToByteArray() + ticket.toByteArray(StandardCharsets.US_ASCII)
            try {
                socket.connect(endpoint)
                socket.soTimeout = 3_000
                socket.send(DatagramPacket(bind, bind.size))
                val ackBytes = ByteArray(8)
                val ack = DatagramPacket(ackBytes, ackBytes.size)
                socket.receive(ack)
                require(ack.length == 8 && ackBytes.copyOfRange(0, 4).contentEquals("PTTA".encodeToByteArray())) {
                    "relay binding acknowledgement is invalid"
                }
                val acknowledged = ByteBuffer.wrap(ackBytes, 4, 4).int.toLong() and 0xffff_ffffL
                require(acknowledged == expectedSenderDemux) { "relay acknowledged the wrong sender demux" }
                socket.soTimeout = minOf(1_000, heartbeatIntervalMillis.coerceAtLeast(10)).toInt()
            } catch (error: Throwable) {
                socket.close()
                throw error
            }
            lateinit var result: AuthenticatedUdpRelay
            val expectedAck = "PTTA".encodeToByteArray() + ByteBuffer.allocate(4).putInt(expectedSenderDemux.toInt()).array()
            val receiver =
                thread(start = false, name = "ptt-udp-relay-receive", priority = Thread.NORM_PRIORITY + 1) {
                    val storage = ByteArray(MEDIA_DATAGRAM_BYTES + 1)
                    var nextProbeAt = monotonicMillis() + heartbeatIntervalMillis
                    var probeDeadline = Long.MAX_VALUE
                    while (!socket.isClosed && !Thread.currentThread().isInterrupted) {
                        val packet = DatagramPacket(storage, storage.size)
                        try {
                            socket.receive(packet)
                            if (packet.length == MEDIA_DATAGRAM_BYTES) {
                                onMedia(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
                            } else if (
                                packet.length == expectedAck.size &&
                                    packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                                        .contentEquals(expectedAck)
                            ) {
                                probeDeadline = Long.MAX_VALUE
                                nextProbeAt = monotonicMillis() + heartbeatIntervalMillis
                            }
                        } catch (_: SocketTimeoutException) {
                            val now = monotonicMillis()
                            if (probeDeadline != Long.MAX_VALUE && now >= probeDeadline) {
                                onError(SocketTimeoutException("relay heartbeat timed out"))
                                break
                            }
                            if (probeDeadline == Long.MAX_VALUE && now >= nextProbeAt) {
                                try {
                                    socket.send(DatagramPacket(bind, bind.size))
                                    probeDeadline = now + heartbeatTimeoutMillis
                                } catch (error: Throwable) {
                                    if (!socket.isClosed) onError(error)
                                    break
                                }
                            }
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

        private fun monotonicMillis(): Long = System.nanoTime() / 1_000_000
    }
}
