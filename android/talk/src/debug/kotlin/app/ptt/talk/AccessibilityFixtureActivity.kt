package app.ptt.talk

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import app.ptt.crypto.persistence.EncryptedChatEventRecord
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.time.Instant
import java.util.UUID
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.util.KeyHelper

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
            EncryptedSignalProtocolStore.resetLocalDeviceState(this)
            EncryptedSignalProtocolStore.open(
                this,
                IdentityKeyPair.generate(),
                KeyHelper.generateRegistrationId(false),
            ).use(::seedConversation)
            store.save(
                DeviceSession(
                    serverUrl = "http://10.0.2.2:39183",
                    aci = LOCAL_ACI,
                    deviceId = 1,
                    mailboxId = "accessibility-fixture-mailbox",
                    accessToken = "accessibility-fixture-token",
                ),
            )
        }
        startActivity(
            Intent(this, TalkActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(EXTRA_DEBUG_ALLOW_SCREENSHOTS, true)
                if (screen == SCREEN_CHAT) {
                    putExtra(PttMessagingService.EXTRA_OPEN_CHAT, true)
                    putExtra(PttMessagingService.EXTRA_CHAT_CHANNEL_ID, FIXTURE_CHANNEL_ID)
                }
            },
        )
        finish()
    }

    private fun seedConversation(store: EncryptedSignalProtocolStore) {
        val now = Instant.now()
        val channelId = UUID.fromString(FIXTURE_CHANNEL_ID)
        val messages = listOf(
            ChatMessage(
                messageId = UUID.fromString("22222222-2222-4222-8222-222222222222"),
                channelId = channelId,
                membershipEpoch = 1,
                sentAt = now.minusSeconds(120),
                senderAci = TEAMMATE_ACI,
                senderDeviceId = 1,
                kind = ChatContentKind.TEXT,
                text = "Arrived at the east entrance. Everything is clear.",
            ),
            ChatMessage(
                messageId = UUID.fromString("33333333-3333-4333-8333-333333333333"),
                channelId = channelId,
                membershipEpoch = 1,
                sentAt = now.minusSeconds(60),
                senderAci = LOCAL_ACI,
                senderDeviceId = 1,
                kind = ChatContentKind.TEXT,
                text = "Copy. Send a voice update when the team is in position.",
            ),
            ChatMessage(
                messageId = UUID.fromString("44444444-4444-4444-8444-444444444444"),
                channelId = channelId,
                membershipEpoch = 1,
                sentAt = now.minusSeconds(20),
                senderAci = TEAMMATE_ACI,
                senderDeviceId = 1,
                kind = ChatContentKind.VOICE,
                text = "Voice update",
                attachment = ChatAttachment(
                    attachmentId = UUID.fromString("55555555-5555-4555-8555-555555555555"),
                    fileName = "voice-update.m4a",
                    mimeType = "audio/mp4",
                    plaintextBytes = 75_000,
                    durationMs = 12_000,
                    waveform = byteArrayOf(32, 58, 91, 45, 103, 74, 40, 88, 60, 96, 52, 79),
                    key = ByteArray(32) { (it + 1).toByte() },
                    ciphertextSha256 = ByteArray(32) { (it + 33).toByte() },
                ),
            ),
        )
        messages.forEach { message ->
            val event = ChatEvent.message(message)
            store.putChatEvent(
                EncryptedChatEventRecord(
                    eventId = event.eventId.toString(),
                    channelId = event.channelId.toString(),
                    senderAci = event.senderAci,
                    senderDeviceId = event.senderDeviceId,
                    sentAtMs = event.sentAt.toEpochMilli(),
                    expiresAtMs = now.plusSeconds(30L * 24 * 60 * 60).toEpochMilli(),
                    payload = EncryptedChatCodec.encodeEvent(event),
                ),
            )
        }
    }

    private companion object {
        const val EXTRA_SCREEN = "screen"
        const val SCREEN_ONBOARDING = "onboarding"
        const val SCREEN_CHAT = "chat"
        const val FIXTURE_CHANNEL_ID = "11111111-1111-4111-8111-111111111111"
        const val LOCAL_ACI = "9d401a02-84a1-4a03-8cb7-30f213f58431"
        const val TEAMMATE_ACI = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        const val EXTRA_DEBUG_ALLOW_SCREENSHOTS = "app.ptt.talk.extra.DEBUG_ALLOW_SCREENSHOTS"
    }
}
