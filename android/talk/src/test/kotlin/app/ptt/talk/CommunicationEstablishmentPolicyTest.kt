package app.ptt.talk

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CommunicationEstablishmentPolicyTest {
    @Test
    fun `metadata refresh is reserved for stale epoch responses`() {
        assertFalse(CommunicationEstablishmentPolicy.requiresMetadataRefresh(null, null))
        assertFalse(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "FLOOR_BUSY"))
        assertTrue(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "STALE_MEMBERSHIP_EPOCH"))
        assertTrue(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "MEMBERSHIP_EPOCH_MISMATCH"))
    }

    @Test
    fun `unknown packets coalesce mailbox wakeups`() {
        val gate = ExpeditedMailboxPollGate()
        assertTrue(gate.begin())
        assertFalse(gate.begin())
        assertTrue(gate.finish())
        assertFalse(gate.finish())
        assertTrue(gate.begin())
    }
}
