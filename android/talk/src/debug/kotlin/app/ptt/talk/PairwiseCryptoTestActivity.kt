package app.ptt.talk

import android.app.Activity
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.widget.TextView
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.util.UUID
import kotlin.concurrent.thread
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.util.KeyHelper

/** Debug-only two-device probe for SQLCipher + PQXDH + Double Ratchet + mailbox fan-out. */
class PairwiseCryptoTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val view = TextView(this).apply { text = "Running pairwise crypto probe…" }
        setContentView(view)
        thread(name = "ptt-pairwise-crypto-smoke") {
            val status = runCatching { runProbe() }.fold({ "PASS $it" }, { "FAIL ${it::class.java.simpleName}: ${it.message}" })
            Log.i(TAG, status)
            runOnUiThread { view.text = status }
        }
    }

    private fun runProbe(): String {
        val server = requireNotNull(intent.getStringExtra("server"))
        val aci = requireNotNull(intent.getStringExtra("aci"))
        val deviceId = intent.getIntExtra("deviceId", 1)
        val mailboxId = requireNotNull(intent.getStringExtra("mailboxId"))
        val token = requireNotNull(intent.getStringExtra("token"))
        val mode = requireNotNull(intent.getStringExtra("mode"))
        val session = DeviceSession(server, aci, deviceId, mailboxId, token)
        SecureDeviceStore(this).save(session)
        if (intent.getBooleanExtra("reset", false)) {
            EncryptedSignalProtocolStore.resetLocalDeviceState(this)
        }
        val identity =
            runCatching { EncryptedSignalProtocolStore.open(this).use { it.identityKeyPair } }
                .getOrElse {
                    IdentityKeyPair.generate().also { generated ->
                        EncryptedSignalProtocolStore.open(
                            this,
                            generated,
                            KeyHelper.generateRegistrationId(false),
                        ).close()
                    }
                }
        val identityText =
            Base64.encodeToString(
                identity.publicKey.serialize(),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
        Log.i(TAG, "IDENTITY $aci $identityText")
        val crypto = PersistentPairwiseCrypto(this, session)
        return when (mode) {
            "init" -> {
                crypto.ensurePreKeysPublished(initialBatchSize = 4)
                "initialized $identityText"
            }
            "send" -> {
                val channel = UUID.fromString(requireNotNull(intent.getStringExtra("channelId")))
                val devices = ControlApi(server).channelDevices(session, channel.toString())
                val talk = UUID.randomUUID()
                val accepted =
                    crypto.announceMediaEpoch(
                        devices,
                        MediaEpochAnnouncement(
                            channel,
                            talk,
                            intent.getIntExtra("membershipEpoch", 1),
                            42,
                            9u,
                            ByteArray(32) { (it + 1).toByte() },
                            30_000,
                        ),
                    )
                check(accepted == devices.size - 1) { "not every remote device accepted the announcement" }
                "sent talk=$talk recipients=$accepted"
            }
            "receive" -> {
                val api = ControlApi(server)
                val items = api.mailboxItems(session)
                check(items.isNotEmpty()) { "mailbox is empty" }
                val opened = crypto.decryptEnvelope(items.first().envelope)
                check(opened.announcement.baseKey.contentEquals(ByteArray(32) { (it + 1).toByte() }))
                api.acknowledgeMailbox(session, listOf(items.first().itemId))
                "received sender=${opened.senderAci}:${opened.senderDeviceId} talk=${opened.announcement.talkId}"
            }
            "prepare-service" -> {
                val channel = testChannel()
                PttSessionService.arm(this)
                PttSessionService.prepare(this, channel)
                "service preparation requested"
            }
            "begin-service" -> {
                PttSessionService.beginTransmit(this, testChannel())
                "service transmission requested"
            }
            "end-service" -> {
                PttSessionService.endTransmit(this)
                "service release requested"
            }
            else -> error("unknown mode")
        }
    }

    private fun testChannel(): ChannelSummary =
        ChannelSummary(
            requireNotNull(intent.getStringExtra("channelId")),
            intent.getStringExtra("channelName") ?: "Integration",
            "team",
            intent.getIntExtra("membershipEpoch", 1),
            30,
            intent.getStringExtra("role") ?: "talk",
        )

    private companion object {
        const val TAG = "PTT_PAIRWISE_TEST"
    }
}
