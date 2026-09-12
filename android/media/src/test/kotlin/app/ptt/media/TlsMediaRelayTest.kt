package app.ptt.media

import java.io.IOException
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class TlsMediaRelayTest {
    private class FakeRelay(
        private val sendError: Throwable? = null,
        private val floorError: Throwable? = null,
        private val floorGrant: MediaFloorGrant? = null,
    ) : MediaRelay {
        var closed = false
        var sent = 0
        var floorRequests = 0

        override fun send(packet: ByteArray) {
            sendError?.let { throw it }
            sent += 1
        }

        override fun requestFloor(
            requestToken: String,
            membershipEpoch: Int,
            requestedTotMs: Int,
            sos: Boolean,
        ): MediaFloorGrant? {
            floorRequests += 1
            floorError?.let { throw it }
            return floorGrant
        }

        override fun close() {
            closed = true
        }
    }

    @Test
    fun `derives websocket TLS endpoint without retaining base query or path`() {
        assertEquals(
            "wss://ptt.example.test/v1/media/tunnel?channelId=54b86f25-447f-4abc-a885-7c2e6b2c109c",
            tlsMediaWebSocketUrl(
                "https://ptt.example.test/ignored?secret=no",
                "54b86f25-447f-4abc-a885-7c2e6b2c109c",
            ),
        )
        assertEquals(
            "ws://127.0.0.1:8080/v1/media/tunnel?channelId=54b86f25-447f-4abc-a885-7c2e6b2c109c",
            tlsMediaWebSocketUrl(
                "http://127.0.0.1:8080",
                "54b86f25-447f-4abc-a885-7c2e6b2c109c",
            ),
        )
        assertThrows(IllegalArgumentException::class.java) {
            tlsMediaWebSocketUrl("https://ptt.example.test", "not-a-uuid")
        }
    }

    @Test
    fun `reconnects TLS and retries an interrupted media send once`() {
        val failed = FakeRelay(sendError = IOException("network changed"))
        val recovered = FakeRelay()
        val changes = mutableListOf<String>()
        val relay = AdaptiveMediaRelay.createForTest(
            failed,
            onTransportChanged = changes::add,
            tlsFactory = { recovered },
        )

        relay.send(ByteArray(MEDIA_DATAGRAM_BYTES))

        assertTrue(failed.closed)
        assertEquals(1, recovered.sent)
        assertEquals(listOf("Encrypted media reconnected over TLS."), changes)
    }

    @Test
    fun `reconnects before retrying authenticated floor control`() {
        val token = "abcdefghijklmnopqrstuv"
        val failed = FakeRelay(floorError = MediaRelayConnectionException("socket closed"))
        val grant = MediaFloorGrant(true, token, 30_000, null)
        val recovered = FakeRelay(floorGrant = grant)
        val relay = AdaptiveMediaRelay.createForTest(failed, tlsFactory = { recovered })

        assertEquals(grant, relay.requestFloor(token, 7, 30_000, false))
        assertTrue(failed.closed)
        assertEquals(1, recovered.floorRequests)
    }

    @Test
    fun `reconnects again when an established fallback later fails`() {
        val initial = FakeRelay(sendError = IOException("UDP interrupted"))
        val firstTls = FakeRelay()
        val secondTls = FakeRelay()
        val failureCallbacks = mutableListOf<(Throwable) -> Unit>()
        var factoryCalls = 0
        val relay = AdaptiveMediaRelay.createForTest(
            initial,
            tlsFactory = { onFailure ->
                failureCallbacks += onFailure
                if (factoryCalls++ == 0) firstTls else secondTls
            },
        )
        val packet = ByteArray(MEDIA_DATAGRAM_BYTES)

        relay.send(packet)
        failureCallbacks.single()(IOException("TLS network changed"))
        relay.send(packet)

        assertTrue(firstTls.closed)
        assertEquals(1, firstTls.sent)
        assertEquals(1, secondTls.sent)
        assertEquals(2, factoryCalls)
    }

    @Test
    fun `does not reconnect for malformed application input`() {
        val failed = FakeRelay(sendError = IllegalArgumentException("bad packet"))
        var reconnects = 0
        val relay = AdaptiveMediaRelay.createForTest(
            failed,
            tlsFactory = {
                reconnects += 1
                FakeRelay()
            },
        )

        assertThrows(IllegalArgumentException::class.java) {
            relay.send(ByteArray(MEDIA_DATAGRAM_BYTES))
        }
        assertEquals(0, reconnects)
    }
}
