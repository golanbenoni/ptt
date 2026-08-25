package app.ptt.hardware

import app.ptt.crypto.ChannelId
import app.ptt.floor.FloorState
import app.ptt.floor.InMemoryFloorController
import app.ptt.floor.TalkTarget
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class HardwarePttRouterTest {
    private val target = TalkTarget.Channel(ChannelId(UUID.randomUUID()))

    @Test
    fun `duplicate and overlapping hardware inputs cannot bypass floor transitions`() {
        val floor = InMemoryFloorController()
        val audit = mutableListOf<HardwareAuditEvent>()
        val router = HardwarePttRouter(floor, { target }, audit::add)
        assertTrue(router.button(HardwarePttSource.BLUETOOTH_HID, true))
        assertTrue(router.isAnyHeld())
        assertInstanceOf(FloorState.Requesting::class.java, floor.state.value)
        assertFalse(router.button(HardwarePttSource.BLUETOOTH_HID, true))
        assertTrue(router.button(HardwarePttSource.USB_HID, true))
        assertTrue(router.button(HardwarePttSource.BLUETOOTH_HID, false))
        assertInstanceOf(FloorState.Requesting::class.java, floor.state.value)
        assertTrue(router.button(HardwarePttSource.USB_HID, false))
        assertFalse(router.isAnyHeld())
        assertEquals(FloorState.Idle, floor.state.value)
        assertEquals(listOf("down", "down", "down", "up", "up"), audit.map { it.action })
    }

    @Test
    fun `missing target rejects normal and SOS input`() {
        val floor = InMemoryFloorController()
        val router = HardwarePttRouter(floor, { null })
        assertFalse(router.button(HardwarePttSource.HEADSET, true))
        assertFalse(router.sos(HardwarePttSource.OEM, silent = true))
        assertEquals(FloorState.Idle, floor.state.value)
    }

    @Test
    fun `normal SOS remains held until release and reset clears toggle sources`() {
        val floor = InMemoryFloorController()
        val router = HardwarePttRouter(floor, { target })
        assertTrue(router.sos(HardwarePttSource.SCREEN, silent = false))
        assertTrue(router.isHeld(HardwarePttSource.SCREEN))
        assertFalse(router.sos(HardwarePttSource.OEM, silent = false))
        assertTrue(router.button(HardwarePttSource.SCREEN, false))
        assertFalse(router.isHeld(HardwarePttSource.SCREEN))
        assertTrue(router.button(HardwarePttSource.TILE, true))
        router.reset()
        assertFalse(router.isHeld(HardwarePttSource.TILE))
    }
}
