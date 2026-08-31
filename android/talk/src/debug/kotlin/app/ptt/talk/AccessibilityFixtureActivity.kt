package app.ptt.talk

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Debug-only entry point that puts the production activity into deterministic
 * enrolled states for emulator accessibility checks. No fixture credential or
 * cleartext endpoint is compiled into release builds.
 */
class AccessibilityFixtureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val screen = intent.getStringExtra(EXTRA_SCREEN).orEmpty()
        val store = SecureDeviceStore(this)
        if (screen == SCREEN_ONBOARDING) {
            store.clear()
        } else {
            store.save(
                DeviceSession(
                    serverUrl = "http://10.0.2.2:39183",
                    aci = "accessibility-fixture-account",
                    deviceId = 1,
                    mailboxId = "accessibility-fixture-mailbox",
                    accessToken = "accessibility-fixture-token",
                ),
            )
        }
        startActivity(
            Intent(this, TalkActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK)
                if (screen == SCREEN_CHAT) {
                    putExtra(PttMessagingService.EXTRA_OPEN_CHAT, true)
                    putExtra(PttMessagingService.EXTRA_CHAT_CHANNEL_ID, FIXTURE_CHANNEL_ID)
                }
            },
        )
        finish()
    }

    private companion object {
        const val EXTRA_SCREEN = "screen"
        const val SCREEN_ONBOARDING = "onboarding"
        const val SCREEN_CHAT = "chat"
        const val FIXTURE_CHANNEL_ID = "accessibility-fixture"
    }
}
