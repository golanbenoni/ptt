package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class ControlApiSecurityTest {
    @Test
    fun acceptsOnlyCanonicalHttpsServerOrigins() {
        assertEquals("https://ptt.example.test", canonicalControlServerUrl(" https://ptt.example.test/ "))
        assertThrows(IllegalArgumentException::class.java) {
            canonicalControlServerUrl("https://user:secret@ptt.example.test")
        }
        assertThrows(IllegalArgumentException::class.java) {
            canonicalControlServerUrl("https://ptt.example.test/base?token=value")
        }
        assertThrows(IllegalArgumentException::class.java) {
            canonicalControlServerUrl("http://ptt.example.test")
        }
    }
}
