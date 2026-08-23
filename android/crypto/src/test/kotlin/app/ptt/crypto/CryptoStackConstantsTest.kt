package app.ptt.crypto

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CryptoStackConstantsTest {
    @Test
    fun pqxdhInfoIsFrozen() {
        assertEquals("PTT-PQXDH-v1", CryptoStack.PQXDH_INFO)
        assertTrue(CryptoStack.PQXDH_INFO.length >= 8)
    }
}
