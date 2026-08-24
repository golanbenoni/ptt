package app.ptt.talk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.ptt.hardware.HardwarePttSource

/**
 * Signature-protected bridge for a co-signed BLE GATT or OEM accessory service.
 * The bridge only requests transitions; the session still authenticates the server floor.
 */
class HardwarePttReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!PttSessionService.isArmed(context)) return
        val source = when (intent.getStringExtra(EXTRA_SOURCE)) {
            "ble" -> HardwarePttSource.BLE_GATT
            "usb" -> HardwarePttSource.USB_HID
            "oem" -> HardwarePttSource.OEM
            else -> return
        }
        when (intent.action) {
            ACTION_DOWN -> PttSessionService.hardwareButton(context, source, true)
            ACTION_UP -> PttSessionService.hardwareButton(context, source, false)
            ACTION_SOS -> PttSessionService.hardwareSos(
                context,
                source,
                intent.getBooleanExtra(EXTRA_SILENT, false),
            )
        }
    }

    companion object {
        const val ACTION_DOWN = "app.ptt.talk.hardware.DOWN"
        const val ACTION_UP = "app.ptt.talk.hardware.UP"
        const val ACTION_SOS = "app.ptt.talk.hardware.SOS"
        const val EXTRA_SOURCE = "source"
        const val EXTRA_SILENT = "silent"
    }
}
