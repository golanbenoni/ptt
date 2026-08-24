package app.ptt.talk

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Requires a foreground user gesture before any post-reboot control, media, or microphone work. */
class PttBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            PttSessionService.requireRearmAfterBoot(context)
        }
    }
}
