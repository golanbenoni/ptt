package app.ptt.talk

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.widget.TextView
import androidx.core.telecom.CallEndpointCompat
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.io.File
import java.security.SecureRandom
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
    private val mediaStartLock = Object()
    private val senderStarted = AtomicBoolean(false)
    private val chatStarted = AtomicBoolean(false)
    @Volatile private var currentState = "starting"
    private var mediaStartCount = 0
    private lateinit var role: String
    private var transmissionCount = 5
    private lateinit var channel: ChannelSummary
    private lateinit var channels: List<ChannelSummary>
    private lateinit var activeSession: DeviceSession
    private lateinit var chatRun: String
    private var mode = "matrix"
    private var soakIntervalMs = 300_000L
    private var syntheticCallAudio = false
    private var forceCallSpeaker = false
    private var callProofDurationMs = 5_000L
    private var receiverPlaybackCount = 0
    private val floorLatenciesMs = mutableListOf<Long>()
    private val readyLatenciesMs = mutableListOf<Long>()
    private lateinit var status: TextView

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == PttSessionService.ACTION_DEBUG_MEDIA_STARTED) {
                    if (::role.isInitialized && role == "sender") {
                        synchronized(mediaStartLock) {
                            mediaStartCount += 1
                            mediaStartLock.notifyAll()
                        }
                    }
                    return
                }
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
                    PttSessionService.STATE_PLAYED -> if (role == "receiver") onPlaybackCompleted(intent)
                    PttSessionService.STATE_DENIED -> fail("floor-denied:${bounded(detail)}")
                    PttSessionService.STATE_REVOKED -> fail("device-revoked")
                    PttSessionService.STATE_ERROR -> fail("session:${bounded(detail)}")
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Physical automation must be able to establish the foreground session after
        // an earlier lifecycle check has turned the display off. Showing this debug-only
        // driver over the keyguard makes Android treat its service start as an explicit
        // foreground interaction; it does not unlock the device or ship in release builds.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        status = TextView(this).apply {
            text = "Preparing physical encrypted PTT test…"
            textSize = 18f
            setPadding(32, 64, 32, 32)
        }
        setContentView(status)
        registerReceiver(
            receiver,
            IntentFilter().apply {
                addAction(PttSessionService.ACTION_STATE)
                addAction(PttSessionService.ACTION_DEBUG_MEDIA_STARTED)
            },
            RECEIVER_NOT_EXPORTED,
        )
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
            // Clear the prior launch's terminal state before any network or cryptographic work.
            // The host must never interpret an older failure marker as this launch's result.
            clearMarkers()
            mode = config.optString("mode", "matrix")
            syntheticCallAudio = config.optBoolean("syntheticCallAudio", false)
            forceCallSpeaker = config.optBoolean("forceCallSpeaker", false)
            callProofDurationMs = config.optLong("callProofDurationMs", 5_000L).coerceIn(5_000L, 20_000L)
            require(mode in setOf(
                "matrix", "push-wake-receiver", "restart-receiver", "queue-before-crash",
                "resume-after-crash", "soak-sender", "soak-receiver", "acoustic",
                "call-prepare", "call-caller", "call-callee",
            ))
            transmissionCount = if (mode.startsWith("soak-")) {
                config.optInt("transmissions", 97).coerceIn(2, 512)
            } else {
                config.optInt("transmissions", 5).coerceIn(1, 20)
            }
            soakIntervalMs = config.optLong("soakIntervalMs", 300_000L).coerceIn(60_000L, 3_600_000L)
            val identityFixture = JSONObject(identityFile.readText())
            val identity = IdentityKeyPair(Base64.decode(identityFixture.getString("identityKeyPair"), Base64.DEFAULT))
            val registrationId = identityFixture.getInt("registrationId")
            activeSession =
                DeviceSession(
                    serverUrl = config.getString("serverUrl").trimEnd('/'),
                    aci = UUID.fromString(config.getString("aci")).toString().lowercase(),
                    deviceId = config.getInt("deviceId"),
                    mailboxId = UUID.fromString(config.getString("mailboxId")).toString().lowercase(),
                    accessToken = config.getString("accessToken"),
                )
            val preserveState = config.optBoolean("preserveState", false)
            val skipCryptoInitialization = config.optBoolean("skipCryptoInitialization", false)
            require(!skipCryptoInitialization || (preserveState && mode in setOf("call-caller", "call-callee")))
            if (!skipCryptoInitialization) {
                initializeCryptoAndPublish(identity, registrationId, preserveState)
            }
            chatRun = config.getString("run")
            SecureDeviceStore(this).save(activeSession)
            getSharedPreferences(PttSessionService.DEBUG_E2E_PREFS, MODE_PRIVATE).edit()
                .putBoolean(PttSessionService.DEBUG_E2E_SYNTHETIC_CAPTURE, role == "sender")
                .putBoolean(PttSessionService.DEBUG_E2E_SERVICE_MARKERS, mode == "push-wake-receiver")
                // The first burst can legitimately become encrypted missed history while FCM
                // cold-starts a terminated process. This gate proves that the opaque wake restores
                // live speaker playback; the foreground matrix separately requires every repeated
                // transmission in both directions.
                .putInt(
                    PttSessionService.DEBUG_E2E_SERVICE_MARKER_TARGET,
                    if (mode == "push-wake-receiver") 1 else transmissionCount,
                )
                .commit()
            marker("$role-state", "identity-ready")
            channels = ControlApi(activeSession.serverUrl).channels(activeSession)
            val requestedChannel = config.optString("channelId")
            channel = channels.firstOrNull { it.channelId.equals(requestedChannel, true) }
                ?: channels.firstOrNull()
                ?: error("no-channel")
            when (mode) {
                "call-prepare" -> marker("$role-state", "pass")
                "call-caller", "call-callee" -> startCallAutomation(config)
                "restart-receiver" -> startRestartReceiver()
                "queue-before-crash" -> queueBeforeCrash()
                "resume-after-crash" -> resumeAfterCrash()
                else -> {
                    if (role == "receiver" && mode != "soak-receiver" && mode != "acoustic") {
                        startChatReceiver()
                    }
                    runOnUiThread {
                        PttSessionService.arm(this)
                        PttSessionService.prepare(this, channel)
                    }
                }
            }
        }.onFailure {
            Log.e("PTT_E2E", "Physical E2E setup failed", it)
            fail("setup:${bounded(it.message.orEmpty())}")
        }
    }

    /**
     * Exercises the same API, Core-Telecom service, Double Ratchet exchange, and LiveKit E2EE
     * session as the product UI. The host supplies two different accounts and launches the callee
     * only after reading the caller's opaque call ID marker. No credential or key is written to a
     * marker or log.
     */
    private fun startCallAutomation(config: JSONObject) {
        marker("call-state", "starting")
        val api = ControlApi(activeSession.serverUrl)
        val callId = if (mode == "call-caller") {
            val peerAci = UUID.fromString(config.getString("peerAci")).toString().lowercase()
            require(!peerAci.equals(activeSession.aci, true)) { "call-peer-must-be-another-account" }
            val capabilities = api.callCapabilities(activeSession)
            check(capabilities.enabled && capabilities.mediaReady) { "call-media-not-ready" }
            val call = api.startCall(activeSession, channel.channelId, listOf(peerAci))
            marker("call-created-at-ms", call.createdAt.toEpochMilli().toString())
            // Publish the opaque ID and start Core-Telecom immediately. CallSessionService owns
            // the single call-coordination ratchet and prepares encrypted timeline/session state
            // while the remote devices ring, keeping that work off the answer-to-audio path.
            marker("call-id", call.callId)
            call.callId
        } else {
            UUID.fromString(config.getString("callId")).toString().lowercase()
        }
        marker("call-id", callId)
        runOnUiThread {
            val diagnoseAudio = syntheticCallAudio || forceCallSpeaker ||
                config.optBoolean("diagnosticCallAudio", false)
            if (mode == "call-caller") {
                CallSessionService.outgoing(this, callId, syntheticCallAudio, diagnoseAudio)
            } else {
                CallSessionService.incoming(this, callId, syntheticCallAudio, diagnoseAudio)
            }
        }
        if (mode == "call-callee") {
            val registrationDeadline = System.nanoTime() + 20_000_000_000L
            while (!CallSessionService.snapshot().active && System.nanoTime() < registrationDeadline) {
                Thread.sleep(100)
            }
            check(CallSessionService.snapshot().active) { "call-service-registration-timeout" }
            marker("call-ringing-at-ms", System.currentTimeMillis().toString())
            if (config.optBoolean("waitForPrewarm", false)) {
                val prewarmDeadline = System.nanoTime() + 15_000_000_000L
                while (CallSessionService.snapshot().prewarmReadyAtMs == 0L &&
                    System.nanoTime() < prewarmDeadline
                ) {
                    Thread.sleep(50)
                }
                val prewarmReadyAtMs = CallSessionService.snapshot().prewarmReadyAtMs
                check(prewarmReadyAtMs > 0L) { "call-prewarm-timeout" }
                marker("call-prewarm-ready-at-ms", prewarmReadyAtMs.toString())
            }
            marker("call-answered-at-ms", System.currentTimeMillis().toString())
            runOnUiThread { CallSessionService.answer(this) }
        }

        var connectObservedAt = 0L
        var activeObservedAt = 0L
        var requestedSpeakerName: String? = null
        val deadline = System.nanoTime() + 120_000_000_000L
        while (System.nanoTime() < deadline) {
            val snapshot = CallSessionService.snapshot()
            marker("call-service-status", bounded(snapshot.status))
            marker("call-muted", snapshot.muted.toString())
            marker("call-quality", bounded(snapshot.connectionQuality))
            marker("call-active-speakers", snapshot.activeSpeakerAcis.size.toString())
            marker("call-local-audio-tracks", snapshot.localAudioTracks.toString())
            marker("call-remote-audio-tracks", snapshot.remoteAudioTracks.toString())
            marker("call-e2ee-frame-state", bounded(snapshot.encryptionState))
            marker("call-render-tone-bursts", snapshot.diagnosticToneBursts.toString())
            marker("call-render-peak-rms", "%.6f".format(java.util.Locale.US, snapshot.diagnosticPeakRms))
            marker(
                "call-render-peak-correlation",
                "%.6f".format(java.util.Locale.US, snapshot.diagnosticPeakCorrelation),
            )
            marker("call-capture-tone-bursts", snapshot.captureDiagnosticToneBursts.toString())
            marker(
                "call-capture-peak-rms",
                "%.6f".format(java.util.Locale.US, snapshot.captureDiagnosticPeakRms),
            )
            marker(
                "call-capture-peak-correlation",
                "%.6f".format(java.util.Locale.US, snapshot.captureDiagnosticPeakCorrelation),
            )
            marker("call-capture-format", bounded(snapshot.captureDiagnosticFormat))
            marker("call-render-format", bounded(snapshot.renderDiagnosticFormat))
            marker("call-route", bounded(snapshot.routeName))
            if (forceCallSpeaker && requestedSpeakerName == null) {
                snapshot.routes.firstOrNull { it.type == CallEndpointCompat.TYPE_SPEAKER }?.let { route ->
                    requestedSpeakerName = route.name
                    marker("call-speaker-requested", bounded(route.name))
                    runOnUiThread { CallSessionService.selectRoute(this, route.id) }
                }
            }
            if (snapshot.seatClaimedAtMs > 0L) marker("call-seat-at-ms", snapshot.seatClaimedAtMs.toString())
            if (snapshot.keySentAtMs > 0L) marker("call-key-sent-at-ms", snapshot.keySentAtMs.toString())
            if (snapshot.remoteKeyInstalledAtMs > 0L) {
                marker("call-remote-key-at-ms", snapshot.remoteKeyInstalledAtMs.toString())
            }
            if (snapshot.outboundKeyAckedAtMs > 0L) {
                marker("call-key-acked-at-ms", snapshot.outboundKeyAckedAtMs.toString())
            }
            if (snapshot.prewarmReadyAtMs > 0L) {
                marker("call-prewarm-ready-at-ms", snapshot.prewarmReadyAtMs.toString())
            }
            if (snapshot.keyReadyAtMs > 0L && connectObservedAt == 0L) {
                connectObservedAt = snapshot.keyReadyAtMs
                marker("call-connect-at-ms", connectObservedAt.toString())
            }
            if (snapshot.mediaConnectedAtMs > 0L) {
                marker("call-media-connected-at-ms", snapshot.mediaConnectedAtMs.toString())
            }
            if (!snapshot.active) {
                if (activeObservedAt != 0L) error("call-service-ended-before-proof")
                Thread.sleep(200)
                continue
            }
            val serverCall = api.call(activeSession, callId)
            val routeReady = !forceCallSpeaker ||
                (requestedSpeakerName != null && snapshot.routeName.contains("speaker", ignoreCase = true))
            if (snapshot.status == "Encrypted call active" && !snapshot.muted && routeReady &&
                serverCall.state == "active"
            ) {
                if (activeObservedAt == 0L) {
                    activeObservedAt = System.currentTimeMillis()
                    marker("call-active-at-ms", activeObservedAt.toString())
                    marker("call-state", "active")
                }
                if (System.currentTimeMillis() - activeObservedAt >= callProofDurationMs) {
                    marker("call-state", "pass")
                    return
                }
            }
            Thread.sleep(200)
        }
        error("call-active-audio-timeout")
    }

    /**
     * Automation intentionally recreates its encrypted store while the production server retains
     * consumed prekey IDs to detect unsafe reuse. A cryptographically random high counter makes a
     * collision vanishingly unlikely; bounded regeneration also makes the diagnostic resilient to
     * any retained test fixture that happens to occupy the chosen range. Normal app state never
     * takes this path and keeps monotonically persisted counters.
     */
    private fun initializeCryptoAndPublish(
        identity: IdentityKeyPair,
        registrationId: Int,
        preserveState: Boolean,
    ) {
        val maximumAttempts = if (preserveState) 1 else 5
        if (!preserveState) File(filesDir, "ptt-e2e-prekey-diagnostic.txt").delete()
        repeat(maximumAttempts) { attempt ->
            if (!preserveState) EncryptedSignalProtocolStore.resetLocalDeviceState(this)
            val recordIdStart = SecureRandom().nextInt(1_000_000_000) + 1_000_000_000
            EncryptedSignalProtocolStore.open(
                this,
                identity,
                registrationId,
                initialRecordIdStart = recordIdStart,
            ).use { store ->
                if (!preserveState) {
                    store.seedEmptyApplicationRecordIds(recordIdStart)
                    check(
                        store.applicationState("id-ec-prekey")
                            ?.decodeToString()
                            ?.toIntOrNull() == recordIdStart,
                    ) { "automation record ID seed was not persisted" }
                }
            }
            if (!preserveState) {
                recordPrekeyDiagnostic("attempt=${attempt + 1} record-id-start=$recordIdStart")
                Log.i(
                    "PTT_E2E_MARKER",
                    "prekey-attempt=${attempt + 1} record-id-start=$recordIdStart",
                )
            }
            try {
                val startedAt = System.nanoTime()
                PersistentPairwiseCrypto(this, activeSession).ensurePreKeysPublished(
                    initialBatchSize = 8,
                    replenishmentBatchSize = 4,
                    replaceExisting = !preserveState,
                ) { step ->
                    val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000
                    recordPrekeyDiagnostic("step=$step elapsed-ms=$elapsedMs")
                }
                return
            } catch (error: ControlApiException) {
                if (error.code != "PREKEY_ID_REUSED" || attempt == maximumAttempts - 1) throw error
                recordPrekeyDiagnostic("collision=${attempt + 1} record-id-start=$recordIdStart")
                Log.w(
                    "PTT_E2E_MARKER",
                    "prekey-collision=${attempt + 1} record-id-start=$recordIdStart",
                )
            }
        }
        error("prekey initialization attempts exhausted")
    }

    private fun startRestartReceiver() {
        marker("chat-restart-receiver-state", "polling")
        chatWorker.execute {
            runCatching {
                val chat = EncryptedChatClient(this, activeSession)
                repeat(240) {
                    if (!pollChatWhenReachable(chat)) {
                        Thread.sleep(500)
                        return@repeat
                    }
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
        if (mode != "soak-sender" && mode != "acoustic") startChatSender()
        worker.execute {
            repeat(transmissionCount) { index ->
                currentState = "ready"
                val expectedMediaStart = synchronized(mediaStartLock) { mediaStartCount + 1 }
                runOnUiThread { PttSessionService.beginTransmit(this, channel) }
                if (!waitForState(PttSessionService.STATE_TRANSMITTING, 15_000)) {
                    fail("no-transmit-${index + 1}:${bounded(currentState)}")
                    return@execute
                }
                if (!waitForMediaStart(expectedMediaStart, 15_000)) {
                    fail("no-media-start-${index + 1}")
                    return@execute
                }
                // Give an independent room microphone a long, unambiguous receiver burst even on
                // devices whose voice speaker is aggressively limited. The latency gate still
                // measures the first audible sample, and production hold-to-talk is unaffected.
                Thread.sleep(1_600)
                runOnUiThread { PttSessionService.endTransmit(this) }
                if (!waitForState(PttSessionService.STATE_READY, 15_000)) {
                    fail("no-release-${index + 1}:${bounded(currentState)}")
                    return@execute
                }
                marker("sender-count", (index + 1).toString())
                if (mode == "soak-sender" && index + 1 < transmissionCount) {
                    marker("sender-state", "soaking")
                    Thread.sleep(soakIntervalMs)
                } else {
                    Thread.sleep(800)
                }
            }
            marker("sender-state", "pass")
        }
    }

    private fun onPlaybackCompleted(intent: Intent) {
        val authenticated = intent.getIntExtra(PttSessionService.EXTRA_AUTHENTICATED_PACKETS, -1)
        val played = intent.getIntExtra(PttSessionService.EXTRA_PLAYED_PACKETS, -1)
        val concealed = intent.getIntExtra(PttSessionService.EXTRA_CONCEALED_FRAMES, -1)
        if (authenticated < PttSessionService.DEBUG_E2E_MIN_PLAYED_FRAMES ||
            played < PttSessionService.DEBUG_E2E_MIN_PLAYED_FRAMES
        ) {
            fail("truncated-playback:$played-of-$authenticated-concealed-$concealed")
            return
        }
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
                    if (!pollChatWhenReachable(chat)) {
                        Thread.sleep(500)
                        return@repeat
                    }
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
                    if (!pollChatWhenReachable(chat)) {
                        Thread.sleep(500)
                        return@repeat
                    }
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
                    marker(
                        "chat-receiver-observed",
                        "messages=${matching.size};base=${base != null};reply=${reply != null};" +
                            "file=${file != null};voice=${voice != null};video=${video != null}",
                    )
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

    private fun pollChatWhenReachable(chat: EncryptedChatClient): Boolean =
        try {
            chat.poll(channels)
            true
        } catch (error: Throwable) {
            if (!CommunicationEstablishmentPolicy.isTransientNetworkFailure(error)) throw error
            false
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

    private fun waitForMediaStart(expectedCount: Int, timeoutMs: Long): Boolean {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        synchronized(mediaStartLock) {
            while (mediaStartCount < expectedCount) {
                val remaining = (deadline - System.nanoTime()) / 1_000_000
                if (remaining <= 0) return false
                mediaStartLock.wait(remaining.coerceAtLeast(1))
            }
        }
        return true
    }

    private fun fail(detail: String) {
        if (mode.startsWith("call-")) marker("call-state", "fail:$detail")
        if (::role.isInitialized) marker("$role-state", "fail:$detail")
        else marker("setup-state", "fail:$detail")
        runOnUiThread { status.text = "Physical test failed\n$detail" }
    }

    private fun marker(name: String, value: String) {
        require(name.matches(Regex("[a-z0-9-]+")))
        File(filesDir, "ptt-e2e-$name.txt").writeText(value)
    }

    private fun recordPrekeyDiagnostic(value: String) {
        File(filesDir, "ptt-e2e-prekey-diagnostic.txt").appendText("$value\n")
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
