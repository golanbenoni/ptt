package app.ptt.media

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class AuthenticatedUdpRelayTest {
    @Test
    fun `authenticated bind sends and receives exact production datagrams`() {
        val server = DatagramSocket(0)
        val sent = ByteArray(MEDIA_DATAGRAM_BYTES) { it.toByte() }
        val echoed = ByteArray(MEDIA_DATAGRAM_BYTES) { (255 - it).toByte() }
        val received = arrayOfNulls<ByteArray>(1)
        val callback = CountDownLatch(1)
        val serverDone = CountDownLatch(1)
        val worker = thread(name = "fake-relay") {
            try {
                val bindBytes = ByteArray(4_096)
                val bind = DatagramPacket(bindBytes, bindBytes.size)
                server.receive(bind)
                assertEquals("PTTBtest-ticket", bind.data.copyOf(bind.length).decodeToString())
                val ack = "PTTA".encodeToByteArray() + ByteBuffer.allocate(4).putInt(42).array()
                server.send(DatagramPacket(ack, ack.size, bind.socketAddress))
                val mediaBytes = ByteArray(MEDIA_DATAGRAM_BYTES + 1)
                val media = DatagramPacket(mediaBytes, mediaBytes.size)
                server.receive(media)
                assertArrayEquals(sent, media.data.copyOf(media.length))
                server.send(DatagramPacket(echoed, echoed.size, bind.socketAddress))
            } finally {
                serverDone.countDown()
            }
        }
        AuthenticatedUdpRelay.connect("127.0.0.1:${server.localPort}", "test-ticket", 42, {
            received[0] = it
            callback.countDown()
        }).use { relay ->
            relay.send(sent)
            assertTrue(callback.await(3, TimeUnit.SECONDS))
            assertArrayEquals(echoed, received[0])
        }
        assertTrue(serverDone.await(3, TimeUnit.SECONDS))
        worker.join(1_000)
        server.close()
    }

    @Test
    fun `wrong demux acknowledgement fails closed`() {
        val server = DatagramSocket(0)
        val worker = thread(name = "fake-relay-wrong-demux") {
            val bind = DatagramPacket(ByteArray(4_096), 4_096)
            server.receive(bind)
            val ack = "PTTA".encodeToByteArray() + ByteBuffer.allocate(4).putInt(43).array()
            server.send(DatagramPacket(ack, ack.size, bind.socketAddress))
        }
        assertThrows(IllegalArgumentException::class.java) {
            AuthenticatedUdpRelay.connect("udp://127.0.0.1:${server.localPort}", "ticket", 42, {})
        }
        worker.join(1_000)
        server.close()
    }

    @Test
    fun `missing authenticated heartbeat reports a dead UDP path`() {
        val server = DatagramSocket(0)
        val heartbeatSeen = CountDownLatch(1)
        val worker = thread(name = "fake-relay-heartbeat") {
            val bind = DatagramPacket(ByteArray(4_096), 4_096)
            server.receive(bind)
            val ack = "PTTA".encodeToByteArray() + ByteBuffer.allocate(4).putInt(42).array()
            server.send(DatagramPacket(ack, ack.size, bind.socketAddress))
            val heartbeat = DatagramPacket(ByteArray(4_096), 4_096)
            server.receive(heartbeat)
            assertEquals("PTTBticket", heartbeat.data.copyOf(heartbeat.length).decodeToString())
            heartbeatSeen.countDown()
            // Deliberately omit the second acknowledgement to simulate a silent UDP black hole.
        }
        val failed = CountDownLatch(1)
        AuthenticatedUdpRelay.connect(
            "127.0.0.1:${server.localPort}",
            "ticket",
            42,
            {},
            { failed.countDown() },
            heartbeatIntervalMillis = 50,
            heartbeatTimeoutMillis = 100,
        ).use {
            assertTrue(heartbeatSeen.await(2, TimeUnit.SECONDS))
            assertTrue(failed.await(2, TimeUnit.SECONDS))
        }
        worker.join(1_000)
        server.close()
    }

    @Test
    fun `endpoint parser supports bracketed IPv6 and rejects missing ports`() {
        val endpoint = AuthenticatedUdpRelay.parseEndpoint("udp://[::1]:47000")
        assertEquals(47_000, endpoint.port)
        assertThrows(IllegalArgumentException::class.java) {
            AuthenticatedUdpRelay.parseEndpoint("relay.example")
        }
    }
}
