package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class CallUserMessageTest {
    @Test
    fun accountSeatErrorsExplainLinkedDeviceBehavior() {
        assertEquals(
            "This account is already in a call on another linked device. End that call first, or use a second test account to call between your devices.",
            callServerErrorMessage("ACCOUNT_ALREADY_IN_CALL"),
        )
        assertEquals(
            "This call was answered on your other linked device.",
            callServerErrorMessage("CALL_ANSWERED_ELSEWHERE"),
        )
        assertEquals(
            "Continue this call from the linked device that answered it.",
            callServerErrorMessage("CALL_ACTIVE_DEVICE_REQUIRED"),
        )
        assertNull(callServerErrorMessage("UNKNOWN"))
    }
}
