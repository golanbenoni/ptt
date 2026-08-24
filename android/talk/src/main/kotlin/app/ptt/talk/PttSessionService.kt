package app.ptt.talk

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import app.ptt.audio.AndroidAudioEngine

/**
 * User-armed foreground lifetime for control, crypto, floor, and audio work.
 *
 * It deliberately has no boot receiver: after a reboot the user must open the app and tap Stay
 * connected before microphone-capable background operation can resume.
 */
class PttSessionService : Service() {
    private lateinit var audio: AndroidAudioEngine

    override fun onCreate() {
        super.onCreate()
        audio = AndroidAudioEngine(this)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISARM) {
            setArmed(this, false)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
            SecureDeviceStore(this).load() == null
        ) {
            setArmed(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        setArmed(this, true)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        setArmed(this, false)
        audio.close()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val open =
            PendingIntent.getActivity(
                this,
                1,
                Intent(this, TalkActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val disconnect =
            PendingIntent.getService(
                this,
                2,
                Intent(this, PttSessionService::class.java).setAction(ACTION_DISARM),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("PTT Talk is connected")
            .setContentText("Ready for private-team calls. Tap to open.")
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Disconnect", disconnect).build())
            .build()
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Active PTT session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown only after you arm Stay connected."
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    companion object {
        private const val CHANNEL_ID = "ptt-active-session-v1"
        private const val NOTIFICATION_ID = 4101
        private const val ACTION_ARM = "app.ptt.talk.ARM"
        private const val ACTION_DISARM = "app.ptt.talk.DISARM"
        private const val PREFS = "ptt-session-lifecycle-v1"
        private const val ARMED = "armed"

        fun arm(context: Context) {
            context.startForegroundService(Intent(context, PttSessionService::class.java).setAction(ACTION_ARM))
        }

        fun disarm(context: Context) {
            context.startService(Intent(context, PttSessionService::class.java).setAction(ACTION_DISARM))
        }

        fun isArmed(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ARMED, false)

        private fun setArmed(context: Context, armed: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ARMED, armed).apply()
        }
    }
}
