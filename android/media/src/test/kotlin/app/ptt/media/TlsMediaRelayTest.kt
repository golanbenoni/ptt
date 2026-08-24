package app.ptt.media

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class TlsMediaRelayTest {
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
}
