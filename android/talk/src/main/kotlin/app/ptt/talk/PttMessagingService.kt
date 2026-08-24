package app.ptt.talk

import android.content.Context
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
    }

    companion object {
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
