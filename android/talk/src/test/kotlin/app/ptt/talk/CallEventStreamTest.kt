package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CallEventStreamTest {
    @Test
    fun `normalizes the call event endpoint and strips unrelated path state`() {
        assertEquals(
            "wss://ptttalk.app/v1/calls/events",
            callEventWebSocketUrl("https://ptttalk.app/old/path?token=unsafe#fragment", false),
        )
        assertEquals(
            "wss://calls.example.test:8443/v1/calls/events",
            callEventWebSocketUrl("https://calls.example.test:8443", false),
        )
        assertEquals(
            "ws://127.0.0.1:8080/v1/calls/events",
            callEventWebSocketUrl("http://127.0.0.1:8080/base", true),
        )
        assertNull(callEventWebSocketUrl("http://127.0.0.1:8080", false))
        assertNull(callEventWebSocketUrl("not a URL", true))
    }

    @Test
    fun `retired callbacks cannot replace or reconnect over the active stream`() {
        val state = CallEventConnectionState<Any>()
        val first = Any()
        val second = Any()

        assertTrue(state.beginConnect())
        assertFalse(state.beginConnect())
        assertTrue(state.attach(first))
        assertTrue(state.opened(first))
        assertTrue(state.accepts(first))

        assertEquals(1L, state.reconnectDelay(first))
        assertFalse(state.accepts(first))
        assertTrue(state.beginConnect())
        assertTrue(state.attach(second))
        assertTrue(state.opened(second))

        assertNull(state.reconnectDelay(first))
        assertFalse(state.accepts(first))
        assertTrue(state.accepts(second))
        assertEquals(1L, state.reconnectDelay(second))
    }

    @Test
    fun `close rejects later attachment and callbacks`() {
        val state = CallEventConnectionState<Any>()
        val connection = Any()

        assertTrue(state.beginConnect())
        assertTrue(state.attach(connection))
        assertEquals(connection, state.close())
        assertFalse(state.beginConnect())
        assertFalse(state.accepts(connection))
        assertNull(state.reconnectDelay(connection))
        assertFalse(state.attach(Any()))
    }
}
