package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class ControlApiSecurityTest {
    @Test
    fun treatsMissingEmptyAndJsonNullOptionalStringsAsAbsent() {
        assertEquals(null, optionalNonBlankJsonString(present = false, explicitNull = false, value = ""))
        assertEquals(null, optionalNonBlankJsonString(present = true, explicitNull = false, value = ""))
        assertEquals(null, optionalNonBlankJsonString(present = true, explicitNull = true, value = "null"))
        assertEquals(null, optionalNonBlankJsonString(present = true, explicitNull = false, value = "null"))
        assertEquals("value", optionalNonBlankJsonString(present = true, explicitNull = false, value = "value"))
    }

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

    @Test
    fun rejectsMalformedTokenSpecificFcmRemovalBeforeNetworkUse() {
        val session = DeviceSession(
            serverUrl = "https://ptt.example.test",
            aci = "11111111-1111-4111-8111-111111111111",
            deviceId = 1,
            mailboxId = "22222222-2222-4222-8222-222222222222",
            accessToken = "fixture",
        )
        assertThrows(IllegalArgumentException::class.java) {
            ControlApi(session.serverUrl).removeFcm(session, "too-short")
        }
    }
}
