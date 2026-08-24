package app.ptt.talk

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import app.ptt.hardware.HardwarePttSource

class PttWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { id ->
            val intent = Intent(context, PttWidgetReceiver::class.java).setAction(ACTION_TOGGLE)
            val pending = PendingIntent.getBroadcast(
                context,
                id,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            manager.updateAppWidget(
                id,
                RemoteViews(context.packageName, R.layout.ptt_widget).apply {
                    setOnClickPendingIntent(R.id.ptt_widget_button, pending)
                },
            )
        }
    }

    companion object { internal const val ACTION_TOGGLE = "app.ptt.talk.WIDGET_TOGGLE" }
}

class PttWidgetReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PttWidgetProvider.ACTION_TOGGLE) return
        if (PttSessionService.isArmed(context)) {
            PttSessionService.toggleHardware(context, HardwarePttSource.WIDGET)
        } else {
            context.startActivity(
                Intent(context, TalkActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            )
        }
    }
}
