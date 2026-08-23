package app.ptt.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

class RelayServer(port: Int = 0, bind: String = "127.0.0.1") : AutoCloseable {
    private val sock = DatagramSocket(InetSocketAddress(bind, port))
    private val members = ConcurrentHashMap<UUID, MutableSet<SocketAddress>>()
    @Volatile private var running = true
    private val worker: Thread

    val port: Int get() = sock.localPort

    init {
        sock.soTimeout = 500
        worker =
            thread(name = "ptt-relay", isDaemon = true) {
                val buf = ByteArray(2048)
                while (running) {
                    try {
                        val pkt = DatagramPacket(buf, buf.size)
                        sock.receive(pkt)
                        val data = buf.copyOf(pkt.length)
                        val from = pkt.socketAddress
                        val ch = Packets.channel(data)
                        when (Packets.type(data)) {
                            Packets.BIND -> {
                                members.computeIfAbsent(ch) { ConcurrentHashMap.newKeySet() }.add(from)
                            }
                            Packets.KEY, Packets.FRAME -> {
                                val dests = members[ch] ?: continue
                                for (d in dests) {
                                    if (d == from) continue
                                    sock.send(DatagramPacket(data, data.size, d))
                                }
                            }
                        }
                    } catch (_: Exception) {
                        // timeout / shutdown
                    }
                }
            }
    }

    override fun close() {
        running = false
        sock.close()
        worker.join(1000)
    }
}
