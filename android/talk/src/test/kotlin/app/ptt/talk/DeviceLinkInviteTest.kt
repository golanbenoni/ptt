package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class DeviceLinkInviteTest {
    @Test
    fun `invite round trips with credentials in the fragment`() {
        val code = "s".repeat(43)
        val url = requireNotNull(deviceLinkInviteUrl("https://team.example.test/", "12345678-1234", code))
        assertTrue(url.startsWith("https://ptttalk.app/link-device#"))
        assertFalse(url.contains("?"))
        assertEquals(DeviceLinkInvite("https://team.example.test", "12345678-1234", code), deviceLinkInvite(url))
    }

    @Test
    fun `invite rejects unsafe servers and unrelated hosts`() {
        val code = "s".repeat(43)
        assertNull(deviceLinkInvite("https://evil.example/link-device#server=https%3A%2F%2Fteam.example&requestId=12345678&code=$code"))
        assertNull(deviceLinkInvite("https://ptttalk.app/link-device#server=http%3A%2F%2Fteam.example&requestId=12345678&code=$code"))
        assertNull(deviceLinkInvite("https://ptttalk.app/link-device#server=https%3A%2F%2Fteam.example&requestId=12345678"))
        assertNull(deviceLinkInvite("https://ptttalk.app/link-device#server=https%3A%2F%2Fteam.example&requestId=12345678&requestId=87654321&code=$code"))
        assertNull(deviceLinkInvite("https://ptttalk.app/link-device#server=https%3A%2F%2Fteam.example&requestId=12345678&code=%GG"))
    }
}
