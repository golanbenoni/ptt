package app.ptt.talk

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.ptt.hardware.HardwarePttSource

/** Optional toggle-lock control. A long-lived armed session and selected channel are required. */
class PttTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.state = if (PttSessionService.isArmed(this)) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            qsTile?.subtitle = if (PttSessionService.isArmed(this)) "Selected channel" else "Open to connect"
        }
        qsTile?.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        if (!PttSessionService.isArmed(this)) {
            val intent = Intent(this, TalkActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(
                        this,
                        0,
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
            return
        }
        PttSessionService.toggleHardware(this, HardwarePttSource.TILE)
    }
}
