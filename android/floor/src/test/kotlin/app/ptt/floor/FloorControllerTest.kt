package app.ptt.floor

import app.ptt.crypto.Aci
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class FloorControllerTest {
    @Test
    fun directAutoGrantWhenPeerAvailable() {
        val bob = Aci(UUID.randomUUID())
        val floor = InMemoryFloorController()
        floor.setDirectPeerPresence(bob, PeerPresence.AVAILABLE)
        floor.pttDown(TalkTarget.Direct(bob))
        val s = floor.state.value
        assertTrue(s is FloorState.Granted)
        assertEquals(TalkTarget.Direct(bob), (s as FloorState.Granted).target)
        floor.pttUp(TalkTarget.Direct(bob))
        assertEquals(FloorState.Idle, floor.state.value)
    }

    @Test
    fun directDoesNotAutoGrantWhenBusy() {
        val bob = Aci(UUID.randomUUID())
        val floor = InMemoryFloorController()
        floor.setDirectPeerPresence(bob, PeerPresence.BUSY)
        floor.pttDown(TalkTarget.Direct(bob))
        assertTrue(floor.state.value is FloorState.Requesting)
    }
}
