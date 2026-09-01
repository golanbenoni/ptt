package app.ptt.talk

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Base64
import android.widget.TextView
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.signal.libsignal.protocol.IdentityKeyPair

/**
 * Debug-only physical-device driver. Secrets are read from the app-private config file placed by
 * adb; they never appear in release builds, intent extras, logs, or screenshots.
 */
class PhysicalE2EActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ptt-physical-e2e")
    }
    private val chatWorker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ptt-physical-chat-e2e")
    }
    private val stateLock = Object()
    private val senderStarted = AtomicBoolean(false)
    private val chatStarted = AtomicBoolean(false)
    @Volatile private var currentState = "starting"
    private lateinit var role: String
    private var transmissionCount = 5
    private lateinit var channel: ChannelSummary
    private lateinit var channels: List<ChannelSummary>
    private lateinit var activeSession: DeviceSession
    private lateinit var chatRun: String
    private var mode = "matrix"
    private var receiverPlaybackCount = 0
    private val floorLatenciesMs = mutableListOf<Long>()
    private val readyLatenciesMs = mutableListOf<Long>()
    private lateinit var status: TextView

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != PttSessionService.ACTION_STATE) return
                val state = intent.getStringExtra(PttSessionService.EXTRA_STATE) ?: return
                val detail = intent.getStringExtra(PttSessionService.EXTRA_DETAIL).orEmpty()
                currentState = state
                synchronized(stateLock) { stateLock.notifyAll() }
                runOnUiThread { status.text = "$state\n$detail" }
                when (state) {
                    PttSessionService.STATE_READY -> onReady()
                    PttSessionService.STATE_REQUESTING -> if (role == "sender") marker("sender-state", "requesting-floor")
                    PttSessionService.STATE_GRANTED -> if (role == "sender") {
                        if (appendLatency("floor-latencies-ms", floorLatenciesMs, intent)) {
                            marker("sender-state", "floor-granted")
                        }
                    }
                    PttSessionService.STATE_TRANSMITTING -> if (role == "sender") {
                        if (appendLatency("ready-latencies-ms", readyLatenciesMs, intent)) {
                            marker("sender-state", "transmitting")
                        }
                    }
                    PttSessionService.STATE_PLAYED -> if (role == "receiver") onPlaybackCompleted()
                    PttSessionService.STATE_DENIED -> fail("floor-denied:${bounded(detail)}")
                    PttSessionService.STATE_REVOKED -> fail("device-revoked")
                    PttSessionService.STATE_ERROR -> fail("session:${bounded(detail)}")
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply {
            text = "Preparing physical encrypted PTT test…"
            textSize = 18f
            setPadding(32, 64, 32, 32)
        }
        setContentView(status)
        registerReceiver(receiver, IntentFilter(PttSessionService.ACTION_STATE), RECEIVER_NOT_EXPORTED)
        worker.execute { initialize() }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(receiver) }
        worker.shutdownNow()
        chatWorker.shutdownNow()
        super.onDestroy()
    }

    private fun initialize() {
        runCatching {
            check(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                "microphone-permission"
            }
            val configFile = File(filesDir, CONFIG_FILE)
            val identityFile = File(filesDir, IDENTITY_FILE)
            val config = JSONObject(configFile.readText())
            configFile.delete()
            role = config.getString("role")
            require(role == "sender" || role == "receiver")
            mode = config.optString("mode", "matrix")
            require(mode in setOf("matrix", "push-wake-receiver", "restart-receiver", "queue-before-crash", "resume-after-crash"))
            transmissionCount = config.optInt("transmissions", 5).coerceIn(1, 20)
            val identityFixture = JSONObject(identityFile.readText())
            val identity = IdentityKeyPair(Base64.decode(identityFixture.getString("identityKeyPair"), Base64.DEFAULT))
            val registrationId = identityFixture.getInt("registrationId")
            if (!config.optBoolean("preserveState", false)) {
                EncryptedSignalProtocolStore.resetLocalDeviceState(this)
            }
            EncryptedSignalProtocolStore.open(this, identity, registrationId).close()
            activeSession =
                DeviceSession(
                    serverUrl = config.getString("serverUrl").trimEnd('/'),
                    aci = UUID.fromString(config.getString("aci")).toString().lowercase(),
                    deviceId = config.getInt("deviceId"),
                    mailboxId = UUID.fromString(config.getString("mailboxId")).toString().lowercase(),
                    accessToken = config.getString("accessToken"),
                )
            chatRun = config.getString("run")
            SecureDeviceStore(this).save(activeSession)
            getSharedPreferences(PttSessionService.DEBUG_E2E_PREFS, MODE_PRIVATE).edit()
                .putBoolean(PttSessionService.DEBUG_E2E_SYNTHETIC_CAPTURE, role == "sender")
                .putBoolean(PttSessionService.DEBUG_E2E_SERVICE_MARKERS, mode == "push-wake-receiver")
                .putInt(PttSessionService.DEBUG_E2E_SERVICE_MARKER_TARGET, transmissionCount)
                .commit()
            clearMarkers()
            marker("$role-state", "identity-ready")
            PersistentPairwiseCrypto(this, activeSession).ensurePreKeysPublished(
                initialBatchSize = 8,
                replenishmentBatchSize = 4,
            )
            channels = ControlApi(activeSession.serverUrl).channels(activeSession)
            val requestedChannel = config.optString("channelId")
            channel = channels.firstOrNull { it.channelId.equals(requestedChannel, true) }
                ?: channels.firstOrNull()
                ?: error("no-channel")
            when (mode) {
                "restart-receiver" -> startRestartReceiver()
                "queue-before-crash" -> queueBeforeCrash()
                "resume-after-crash" -> resumeAfterCrash()
                else -> {
                    if (role == "receiver") startChatReceiver()
                    runOnUiThread {
                        PttSessionService.arm(this)
                        PttSessionService.prepare(this, channel)
                    }
                }
            }
        }.onFailure { fail("setup:${bounded(it.message.orEmpty())}") }
    }

    private fun startRestartReceiver() {
        marker("chat-restart-receiver-state", "polling")
        chatWorker.execute {
            runCatching {
                val chat = EncryptedChatClient(this, activeSession)
                repeat(240) {
                    chat.poll(channels)
                    if (chat.conversation(channel.channelId).any {
                            it.message.text == "PTT E2E restart $chatRun"
                        }
                    ) {
                        marker("chat-restart-receiver-count", "1")
                        marker("chat-restart-receiver-state", "pass")
                        return@execute
                    }
                    Thread.sleep(500)
                }
                error("timeout")
            }.onFailure {
                marker("chat-restart-receiver-state", "fail:${bounded(it.message.orEmpty())}")
            }
        }
    }

    private fun queueBeforeCrash() {
        marker("chat-restart-sender-state", "queueing")
        chatWorker.execute {
            val chat = EncryptedChatClient(this, activeSession, injectedDeliveryFailures = 1)
            runCatching { chat.sendText("PTT E2E restart $chatRun", channel) }
                .onSuccess { marker("chat-restart-sender-state", "fail:unexpected-delivery") }
                .onFailure {
                    val pending = chat.pendingSendCount()
                    marker("chat-restart-sender-count", pending.toString())
                    marker(
                        "chat-restart-sender-state",
                        if (pending == 1) "queued" else "fail:not-durable",
                    )
                }
        }
    }

    private fun resumeAfterCrash() {
        marker("chat-restart-sender-state", "resuming")
        chatWorker.execute {
            val chat = EncryptedChatClient(this, activeSession)
            repeat(120) {
                chat.retryPending(channels)
                val pending = chat.pendingSendCount()
                marker("chat-restart-sender-count", pending.toString())
                if (pending == 0) {
                    marker("chat-restart-sender-state", "pass")
                    return@execute
                }
                Thread.sleep(500)
            }
            marker("chat-restart-sender-state", "fail:retry-timeout")
        }
    }

    private fun onReady() {
        if (role == "receiver") {
            if (receiverPlaybackCount < transmissionCount) marker("receiver-state", "ready")
            return
        }
        if (!senderStarted.compareAndSet(false, true)) return
        startChatSender()
        worker.execute {
            repeat(transmissionCount) { index ->
                currentState = "ready"
                runOnUiThread { PttSessionService.beginTransmit(this, channel) }
                if (!waitForState(PttSessionService.STATE_TRANSMITTING, 15_000)) {
                    fail("no-transmit-${index + 1}:${bounded(currentState)}")
                    return@execute
                }
                Thread.sleep(1_200)
                runOnUiThread { PttSessionService.endTransmit(this) }
                if (!waitForState(PttSessionService.STATE_READY, 15_000)) {
                    fail("no-release-${index + 1}:${bounded(currentState)}")
                    return@execute
                }
                marker("sender-count", (index + 1).toString())
                Thread.sleep(800)
            }
            marker("sender-state", "pass")
        }
    }

    private fun onPlaybackCompleted() {
        receiverPlaybackCount += 1
        marker("receiver-count", receiverPlaybackCount.toString())
        marker(
            "receiver-state",
            if (receiverPlaybackCount >= transmissionCount) "pass" else "receiving",
        )
    }

    private fun appendLatency(name: String, values: MutableList<Long>, intent: Intent): Boolean {
        val value = intent.getLongExtra(PttSessionService.EXTRA_LATENCY_MS, -1)
        if (value < 0) {
            fail("missing-$name")
            return false
        }
        values += value
        marker(name, values.joinToString(","))
        return true
    }

    private fun startChatSender() {
        if (role != "sender" || !chatStarted.compareAndSet(false, true)) return
        marker("chat-sender-state", "sending")
        chatWorker.execute {
            runCatching {
                val chat = EncryptedChatClient(this, activeSession)
                marker("chat-sender-stage", "text")
                val base = chat.sendText("PTT E2E $chatRun text", channel)
                marker("chat-sender-stage", "reply")
                val reply = chat.sendText("PTT E2E $chatRun reply", channel, base.messageId)
                val attachments = mutableMapOf<ChatContentKind, ChatMessage>()
                listOf(ChatContentKind.FILE, ChatContentKind.VOICE, ChatContentKind.VIDEO).forEach { kind ->
                    marker("chat-sender-stage", "attachment-${kind.name.lowercase()}")
                    attachments[kind] =
                        chat.sendAttachment(
                            data = chatPayload(kind),
                            fileName = chatFileName(kind),
                            mimeType = chatMimeType(kind),
                            kind = kind,
                            durationMs = if (kind == ChatContentKind.VOICE) 1_250 else 0,
                            waveform = if (kind == ChatContentKind.VOICE) VOICE_WAVEFORM else byteArrayOf(),
                            thumbnailData = if (kind == ChatContentKind.VIDEO) chatThumbnail() else null,
                            thumbnailWidth = if (kind == ChatContentKind.VIDEO) 320 else 0,
                            thumbnailHeight = if (kind == ChatContentKind.VIDEO) 180 else 0,
                            caption = "PTT E2E $chatRun ${kind.name.lowercase()}",
                            channel = channel,
                        )
                }
                marker("chat-sender-stage", "edit")
                chat.editMessage("PTT E2E $chatRun text edited", base.messageId, channel)
                marker("chat-sender-stage", "reaction")
                chat.sendReaction("👍", base.messageId, channel)
                marker("chat-sender-stage", "pin")
                chat.setPinned(true, base.messageId, channel)
                marker("chat-sender-stage", "star")
                chat.setStarred(channel.channelId, base.messageId, true)
                marker("chat-sender-stage", "delete")
                chat.deleteMessage(checkNotNull(attachments[ChatContentKind.FILE]).messageId, channel)

                repeat(180) {
                    chat.poll(channels)
                    val conversation = chat.conversation(channel.channelId)
                    val baseState = conversation.firstOrNull { it.message.messageId == base.messageId }
                    val replyState = conversation.firstOrNull { it.message.messageId == reply.messageId }
                    val voiceState = conversation.firstOrNull {
                        it.message.messageId == attachments[ChatContentKind.VOICE]?.messageId
                    }
                    if (baseState?.receipts?.values?.any { it >= ChatReceiptState.READ } == true &&
                        voiceState?.receipts?.values?.any { it >= ChatReceiptState.PLAYED } == true &&
                        replyState?.replyToMessageId == base.messageId && baseState.isPinned && baseState.isStarred
                    ) {
                        marker("chat-sender-count", "14")
                        marker("chat-sender-state", "pass")
                        return@execute
                    }
                    Thread.sleep(500)
                }
                error("receipt-timeout")
            }.onFailure { marker("chat-sender-state", "fail:${bounded(it.message.orEmpty())}") }
        }
    }

    private fun startChatReceiver() {
        if (role != "receiver" || !chatStarted.compareAndSet(false, true)) return
        marker("chat-receiver-state", "polling")
        chatWorker.execute {
            runCatching {
                val chat = EncryptedChatClient(this, activeSession)
                repeat(180) {
                    chat.poll(channels)
                    val matching = chat.conversation(channel.channelId).filter {
                        it.message.text.startsWith("PTT E2E $chatRun")
                    }
                    val base = matching.firstOrNull {
                        it.message.kind == ChatContentKind.TEXT && it.message.text == "PTT E2E $chatRun text"
                    }
                    val reply = matching.firstOrNull {
                        it.message.kind == ChatContentKind.TEXT && it.message.text == "PTT E2E $chatRun reply"
                    }
                    val file = matching.firstOrNull { it.message.kind == ChatContentKind.FILE }
                    val voice = matching.firstOrNull { it.message.kind == ChatContentKind.VOICE }
                    val video = matching.firstOrNull { it.message.kind == ChatContentKind.VIDEO }
                    if (matching.size == 5 && base?.displayText == "PTT E2E $chatRun text edited" &&
                        base.reactions.values.contains("👍") && base.isPinned &&
                        reply?.replyToMessageId == base.message.messageId && file?.isDeleted == true &&
                        voice?.message?.attachment?.waveform?.contentEquals(VOICE_WAVEFORM) == true &&
                        video?.message?.attachment?.thumbnail?.width == 320 &&
                        video.message.attachment?.thumbnail?.height == 180
                    ) {
                        listOf(
                            ChatContentKind.FILE to checkNotNull(file),
                            ChatContentKind.VOICE to checkNotNull(voice),
                            ChatContentKind.VIDEO to checkNotNull(video),
                        ).forEach { (kind, item) ->
                            check(chat.attachmentData(item.message).contentEquals(chatPayload(kind)))
                        }
                        check(chat.thumbnailData(video.message).contentEquals(chatThumbnail()))
                        chat.sendReceipt(ChatEventKind.DELIVERED, base.message.messageId, channel)
                        chat.sendReceipt(ChatEventKind.READ, base.message.messageId, channel)
                        chat.sendReceipt(ChatEventKind.PLAYED, voice.message.messageId, channel)
                        marker("chat-receiver-count", "14")
                        marker("chat-receiver-state", "pass")
                        return@execute
                    }
                    Thread.sleep(500)
                }
                error("convergence-timeout")
            }.onFailure { marker("chat-receiver-state", "fail:${bounded(it.message.orEmpty())}") }
        }
    }

    private fun chatPayload(kind: ChatContentKind): ByteArray {
        val prefix = "PTT-E2E-CHAT/$chatRun/${kind.name.lowercase()}/".encodeToByteArray()
        val bodySize = if (kind == ChatContentKind.VIDEO) 65_537 else 4_097
        return prefix + ByteArray(bodySize) { (kind.wire.toInt() * 37).toByte() }
    }

    private fun chatThumbnail(): ByteArray = "PTT-E2E-ENCRYPTED-THUMBNAIL/$chatRun".encodeToByteArray()

    private fun chatFileName(kind: ChatContentKind): String =
        when (kind) {
            ChatContentKind.FILE -> "E2E document.bin"
            ChatContentKind.VOICE -> "E2E voice.m4a"
            ChatContentKind.VIDEO -> "E2E video.mov"
            ChatContentKind.TEXT -> "E2E text.txt"
        }

    private fun chatMimeType(kind: ChatContentKind): String =
        when (kind) {
            ChatContentKind.FILE -> "application/octet-stream"
            ChatContentKind.VOICE -> "audio/mp4"
            ChatContentKind.VIDEO -> "video/quicktime"
            ChatContentKind.TEXT -> "text/plain"
        }

    private fun waitForState(expected: String, timeoutMs: Long): Boolean {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        synchronized(stateLock) {
            while (currentState != expected) {
                val remaining = (deadline - System.nanoTime()) / 1_000_000
                if (remaining <= 0) return false
                stateLock.wait(remaining.coerceAtLeast(1))
            }
        }
        return true
    }

    private fun fail(detail: String) {
        if (::role.isInitialized) marker("$role-state", "fail:$detail")
        else marker("setup-state", "fail:$detail")
        runOnUiThread { status.text = "Physical test failed\n$detail" }
    }

    private fun marker(name: String, value: String) {
        require(name.matches(Regex("[a-z0-9-]+")))
        File(filesDir, "ptt-e2e-$name.txt").writeText(value)
    }

    private fun clearMarkers() {
        filesDir.listFiles()?.filter { it.name.startsWith("ptt-e2e-") && it.name.endsWith(".txt") }
            ?.forEach(File::delete)
        marker("$role-count", "0")
        marker("chat-$role-count", "0")
    }

    private fun bounded(value: String): String =
        value.replace(Regex("[^a-zA-Z0-9._:-]"), "-").take(160).ifBlank { "unknown" }

    private companion object {
        const val CONFIG_FILE = "ptt-e2e-config.json"
        const val IDENTITY_FILE = "ptt-e2e-identity.json"
        val VOICE_WAVEFORM = byteArrayOf(12, 48, 96, 180.toByte(), 255.toByte(), 160.toByte(), 72, 24)
    }
}
