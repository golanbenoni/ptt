package app.ptt.hardware

import app.ptt.floor.FloorController
import app.ptt.floor.PttMode
import app.ptt.floor.TalkTarget

enum class HardwarePttSource { HEADSET, BLUETOOTH_HID, USB_HID, BLE_GATT, OEM, TILE, WIDGET, OVERLAY }

data class HardwareAuditEvent(
    val source: HardwarePttSource,
    val action: String,
    val accepted: Boolean,
)

/**
 * Normalizes accessory/UI inputs into the same FloorController used by the product button.
 * Multiple simultaneously held inputs act as one hold and no source can grant its own floor.
 */
class HardwarePttRouter(
    private val floor: FloorController,
    private val target: () -> TalkTarget?,
    private val audit: (HardwareAuditEvent) -> Unit = {},
) {
    private val held = linkedSetOf<HardwarePttSource>()
    private var activeTarget: TalkTarget? = null

    @Synchronized
    fun button(source: HardwarePttSource, pressed: Boolean): Boolean {
        if (pressed) {
            if (!held.add(source)) {
                audit(HardwareAuditEvent(source, "down", false))
                return false
            }
            if (held.size > 1) {
                audit(HardwareAuditEvent(source, "down", true))
                return true
            }
            val selected = target()
            if (selected == null) {
                held.remove(source)
                audit(HardwareAuditEvent(source, "down", false))
                return false
            }
            activeTarget = selected
            floor.pttDown(selected, PttMode.HOLD)
            audit(HardwareAuditEvent(source, "down", true))
            return true
        }
        if (!held.remove(source)) {
            audit(HardwareAuditEvent(source, "up", false))
            return false
        }
        if (held.isEmpty()) {
            activeTarget?.let(floor::pttUp)
            activeTarget = null
        }
        audit(HardwareAuditEvent(source, "up", true))
        return true
    }

    @Synchronized
    fun sos(source: HardwarePttSource, silent: Boolean): Boolean {
        val selected = target()
        if (selected == null) {
            audit(HardwareAuditEvent(source, if (silent) "silent-sos" else "sos", false))
            return false
        }
        floor.requestSos(selected, silent)
        audit(HardwareAuditEvent(source, if (silent) "silent-sos" else "sos", true))
        return true
    }

    @Synchronized
    fun disconnect(source: HardwarePttSource) {
        button(source, false)
    }
}

object HardwareModule
