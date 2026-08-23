package app.ptt.crypto

import java.util.UUID
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CryptoStackConstantsTest {
    @Test
    fun pqxdhInfoIsFrozen() {
        assertEquals("PTT-PQXDH-v1", CryptoStack.PQXDH_INFO)
        assertTrue(CryptoStack.PQXDH_INFO.length >= 8)
    }

    @Test
    fun channelSafetyNumberGoldenVector() {
        val stack = InMemoryCryptoStack()
        val channel = ChannelId(UUID.fromString("01020304-0506-4708-890a-0b0c0d0e0f10"))
        val keys =
            listOf(
                byteArrayOf(0xff.toByte(), 0x00, 0x01),
                byteArrayOf(0x01, 0x02, 0x03),
                byteArrayOf(0x01, 0x02),
            )

        assertEquals(
            "97091 17570 39220 82073 22946 22001 07901 21643 61272 45285 75076 94158",
            stack.safetyNumberChannel(channel, keys),
        )
        assertEquals(stack.safetyNumberChannel(channel, keys), stack.safetyNumberChannel(channel, keys.reversed()))
    }
}
