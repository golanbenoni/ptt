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
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/** FCM carries only an opaque wake hint; encrypted content remains in the device mailbox. */
class PttMessagingService : FirebaseMessagingService() {
    private data class EncryptedChatNotificationTarget(
        val count: Int,
        val channelId: String,
        val isMention: Boolean,
        val threadRootId: UUID?,
    )

    override fun onRegistered(installationId: String) {
        register(this, installationId)
    }

    override fun onUnregistered(installationId: String) {
        val session = SecureDeviceStore(this).load() ?: return
        // Remove only the token Firebase invalidated. A replacement token may
        // already have been registered while this callback was in flight.
        runCatching { ControlApi(session.serverUrl).removeFcm(session, installationId) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["protocolVersion"] == "1" && message.data["eventType"] == "ringing") {
            val callId = message.data["callId"] ?: return
            if (SecureDeviceStore(this).load() != null &&
                runCatching { java.util.UUID.fromString(callId) }.isSuccess
            ) {
                CallSessionService.incoming(this, callId)
            }
            return
        }
        val kind = message.data["kind"] ?: return
        if (kind == "voice") {
            if (BuildConfig.DEBUG) {
                Log.i("PTT_PUSH", "voice wake received")
                runCatching { File(filesDir, "ptt-e2e-push-wake-state.txt").writeText("received") }
            }
            // Voice wake takes the shortest path back to the already user-armed
            // receive-only foreground session. Android does not permit a process
            // launched from a background push to claim microphone foreground
            // access; that access is added only after an eligible user PTT action.
            // Chat polling must not delay media reconnect.
            if (PttSessionService.hasArmAuthorization(this)) {
                runCatching { PttSessionService.wakeForVoice(this) }
                    .onFailure { error ->
                        Log.w("PTT_PUSH", "Android denied the receive-only voice wake", error)
                        if (BuildConfig.DEBUG) {
                            runCatching { File(filesDir, "ptt-e2e-push-playback-state.txt").writeText("fail:wake") }
                        }
                    }
            }
            return
        }
        if (kind != "mailbox") return
        if (SecureDeviceStore(this).load() == null) return
        chatWakeGeneration.incrementAndGet()
        scheduleChatSync()
    }

    private fun scheduleChatSync() {
        if (!chatSyncRunning.compareAndSet(false, true)) return
        thread(name = "ptt-chat-push") {
            var handledGeneration = -1L
            try {
                do {
                    handledGeneration = chatWakeGeneration.get()
                    syncEncryptedChat()?.let(::notifyEncryptedChat)
                } while (chatWakeGeneration.get() != handledGeneration)
            } finally {
                chatSyncRunning.set(false)
                // Close the narrow race where a wake arrives after the loop's final comparison
                // but before the running flag is released.
                if (chatWakeGeneration.get() != handledGeneration) scheduleChatSync()
            }
        }
    }

    private fun syncEncryptedChat(): EncryptedChatNotificationTarget? {
        val session = SecureDeviceStore(this).load() ?: return null
        return runCatching {
            val channels = ControlApi(session.serverUrl).channels(session)
            val client = EncryptedChatClient(this, session)
            val conversationsBefore = channels.associate { it.channelId to client.conversation(it.channelId) }
            val unreadIdsBefore = conversationsBefore.mapValues { (_, conversation) ->
                conversation.asSequence().filter { it.isUnread }.map { it.message.messageId }.toSet()
            }
            client.poll(channels)
            val conversationsAfter = channels.associate { it.channelId to client.conversation(it.channelId) }
            data class Candidate(
                val channelId: String,
                val item: ChatConversationMessage,
                val isMention: Boolean,
                val threadRootId: UUID?,
            )
            val candidates = channels.flatMap { channel ->
                val conversation = conversationsAfter.getValue(channel.channelId)
                val previous = unreadIdsBefore.getValue(channel.channelId)
                val channelMuted = client.preferences(channel.channelId).isMuted
                conversation.filter { it.isUnread && it.message.messageId !in previous }.mapNotNull { item ->
                    val isMention = ChatMentions.containsLocalMention(item.displayText, session.aci)
                    val rootId = item.replyToMessageId?.let { ChatThreads.rootId(item, conversation) }
                    val threadPreference = rootId?.let {
                        client.threadNotificationPreference(channel.channelId, it)
                    } ?: ChatThreadNotificationPreference.AUTOMATIC
                    val allowed = ChatThreadNotifications.shouldNotify(channelMuted, isMention, threadPreference)
                    if (allowed) Candidate(channel.channelId, item, isMention, rootId) else null
                }
            }
            val target = candidates.maxByOrNull { it.item.message.sentAt } ?: return@runCatching null
            EncryptedChatNotificationTarget(
                count = candidates.size,
                channelId = target.channelId,
                isMention = target.isMention,
                threadRootId = target.threadRootId,
            )
        }.getOrNull()
    }

    private fun notifyEncryptedChat(target: EncryptedChatNotificationTarget) {
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
                .putExtra(EXTRA_CHAT_CHANNEL_ID, target.channelId)
                .apply {
                    target.threadRootId?.let { putExtra(EXTRA_CHAT_THREAD_ROOT_ID, it.toString().lowercase()) }
                },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            CHAT_NOTIFICATION_ID,
            Notification.Builder(this, CHAT_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle(
                    if (target.isMention) "New encrypted mention"
                    else if (target.threadRootId != null && target.count == 1) "New encrypted thread reply"
                    else if (target.count == 1) "New encrypted message" else "${target.count} new encrypted messages",
                )
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
        private val chatSyncRunning = AtomicBoolean(false)
        private val chatWakeGeneration = AtomicLong(0)
        internal const val EXTRA_OPEN_CHAT = "app.ptt.talk.extra.OPEN_CHAT"
        internal const val EXTRA_CHAT_CHANNEL_ID = "app.ptt.talk.extra.CHAT_CHANNEL_ID"
        internal const val EXTRA_CHAT_THREAD_ROOT_ID = "app.ptt.talk.extra.CHAT_THREAD_ROOT_ID"
        fun registerCurrentInstallation(context: Context) {
            if (FirebaseApp.getApps(context).isEmpty()) return
            FirebaseMessaging.getInstance().register()
        }

        private fun register(context: Context, token: String) {
            val session = SecureDeviceStore(context).load() ?: return
            thread(name = "ptt-fcm-register") {
                runCatching { ControlApi(session.serverUrl).registerFcm(session, token) }
                    .onSuccess {
                        if (BuildConfig.DEBUG) runCatching {
                            File(context.filesDir, "ptt-e2e-push-registration-state.txt").writeText("registered")
                        }
                    }
                    .onFailure {
                        if (BuildConfig.DEBUG) runCatching {
                            File(context.filesDir, "ptt-e2e-push-registration-state.txt").writeText("fail")
                        }
                    }
            }
        }
    }
}
