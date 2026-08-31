package app.ptt.talk

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlin.concurrent.thread

/** FCM carries only an opaque wake hint; encrypted content remains in the device mailbox. */
class PttMessagingService : FirebaseMessagingService() {
    override fun onRegistered(installationId: String) {
        register(this, installationId)
    }

    override fun onUnregistered(installationId: String) {
        val session = SecureDeviceStore(this).load() ?: return
        runCatching { ControlApi(session.serverUrl).removeFcm(session) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (PttSessionService.isArmed(this)) PttSessionService.arm(this)
        val session = SecureDeviceStore(this).load() ?: return
        thread(name = "ptt-chat-push") {
            val unread = runCatching {
                val channels = ControlApi(session.serverUrl).channels(session)
                val client = EncryptedChatClient(this, session)
                val before = channels.associate { it.channelId to client.unreadCount(it.channelId) }
                client.poll(channels)
                val after = channels.associate { it.channelId to client.unreadCount(it.channelId) }
                val target = channels.maxByOrNull {
                    after.getValue(it.channelId) - before.getValue(it.channelId)
                }
                val delta = target?.let { after.getValue(it.channelId) - before.getValue(it.channelId) } ?: 0
                if (delta > 0) after.values.sum() to requireNotNull(target).channelId else null
            }.getOrNull()
            if (unread != null) notifyEncryptedChat(unread.first, unread.second)
        }
    }

    private fun notifyEncryptedChat(count: Int, channelId: String) {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHAT_CHANNEL_ID, "Encrypted messages", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, TalkActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(EXTRA_OPEN_CHAT, true)
                // This is local-only data learned after decrypting the mailbox;
                // the upstream FCM wake remains opaque.
                .putExtra(EXTRA_CHAT_CHANNEL_ID, channelId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            CHAT_NOTIFICATION_ID,
            Notification.Builder(this, CHAT_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle(if (count == 1) "New encrypted message" else "$count new encrypted messages")
                .setContentText("Open PTT Talk to view the secure conversation.")
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setContentIntent(open)
                .build(),
        )
    }

    companion object {
        private const val CHAT_CHANNEL_ID = "ptt-encrypted-chat-v1"
        private const val CHAT_NOTIFICATION_ID = 2202
        internal const val EXTRA_OPEN_CHAT = "app.ptt.talk.extra.OPEN_CHAT"
        internal const val EXTRA_CHAT_CHANNEL_ID = "app.ptt.talk.extra.CHAT_CHANNEL_ID"
        fun registerCurrentInstallation(context: Context) {
            if (FirebaseApp.getApps(context).isEmpty()) return
            FirebaseMessaging.getInstance().register()
        }

        private fun register(context: Context, token: String) {
            val session = SecureDeviceStore(context).load() ?: return
            thread(name = "ptt-fcm-register") {
                runCatching { ControlApi(session.serverUrl).registerFcm(session, token) }
            }
        }
    }
}
