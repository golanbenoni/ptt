package app.ptt.talk

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class MessageCaptureCoordinatorTest {
    @Test fun microphoneOwnershipIsExclusiveAndInterruptionPreservesTheNote() {
        val owner = Any()
        var stopped = false
        try {
            assertFalse(MessageCaptureCoordinator.beginNote(owner, true) {})
            assertTrue(MessageCaptureCoordinator.beginNote(owner, false) {
                stopped = true
                MessageCaptureCoordinator.endNote(owner)
            })
            assertFalse(MessageCaptureCoordinator.beginPtt(false))
            MessageCaptureCoordinator.endNote(Any())
            assertFalse(MessageCaptureCoordinator.beginPtt(false))
            MessageCaptureCoordinator.interruptNote()
            assertTrue(stopped)
            assertFalse(MessageCaptureCoordinator.beginPtt(true))
            assertTrue(MessageCaptureCoordinator.beginPtt(false))
            assertFalse(MessageCaptureCoordinator.beginNote(owner, false) {})
            MessageCaptureCoordinator.endPtt()
            assertTrue(MessageCaptureCoordinator.beginNote(owner, false) {})
        } finally {
            MessageCaptureCoordinator.endNote(owner)
            MessageCaptureCoordinator.endPtt()
        }
    }
}
