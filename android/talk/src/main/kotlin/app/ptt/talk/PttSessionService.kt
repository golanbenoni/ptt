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
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.util.Log
import android.content.Intent.EXTRA_KEY_EVENT
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.Button
import app.ptt.audio.AndroidAudioEngine
import app.ptt.crypto.ChannelId
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import app.ptt.crypto.persistence.EncryptedHistoryRecord
import app.ptt.floor.FloorController
import app.ptt.floor.FloorState
import app.ptt.floor.PeerPresence
import app.ptt.floor.PttMode
import app.ptt.floor.TalkTarget
import app.ptt.hardware.HardwarePttRouter
import app.ptt.hardware.HardwarePttSource
import app.ptt.media.AdaptiveMediaRelay
import app.ptt.media.EncryptedHistory
import app.ptt.media.MediaRelay
import app.ptt.media.SFrameException
import java.io.File
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.signal.libsignal.protocol.InvalidMessageException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * User-armed foreground lifetime for control, crypto, floor, and audio work.
 *
 * A boot receiver clears the persisted arm bit. While the current process uses [running] to report
 * whether the service is live, the persisted user authorization survives ordinary process death so
 * an authenticated high-priority voice push can restore the foreground session. Force-stop still
 * prevents Android from delivering that push, and the user must tap Stay connected after reboot.
 */
class PttSessionService : Service() {
    private data class PreparedMediaEpoch(
        val channelId: String,
        val membershipEpoch: Int,
        val distributionId: String,
        val senderDemux: Long,
        val grantedTotMs: Int,
        val isSos: Boolean,
        val announcement: MediaEpochAnnouncement,
    )

    private lateinit var audio: AndroidAudioEngine
    private val worker = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "ptt-session-worker") }
    private val scheduler: ScheduledExecutorService =
        Executors.newScheduledThreadPool(2) { runnable -> Thread(runnable, "ptt-session-scheduled") }
    private val secureRandom = SecureRandom()
    @Volatile private var activeChannel: ChannelSummary? = null
    @Volatile private var relayCredential: RelayCredential? = null
    @Volatile private var relay: MediaRelay? = null
    @Volatile private var outgoing: OutgoingVoiceStream? = null
    @Volatile private var heldFloorToken: String? = null
    @Volatile private var outgoingAnnouncement: MediaEpochAnnouncement? = null
    @Volatile private var outgoingStartedAt: Instant? = null
    private val outgoingPackets = mutableListOf<ByteArray>()
    private val incoming = mutableMapOf<UUID, IncomingVoiceStream>()
    @Volatile private var activeIncomingTalkId: UUID? = null
    private val incomingReadyForPlayback = mutableSetOf<UUID>()
    private val incomingSuppressedByCall = mutableSetOf<UUID>()
    private val sosPreemptionScheduled = mutableSetOf<UUID>()
    private val pendingMedia = ArrayDeque<Pair<Long, ByteArray>>()
    private val expeditedMailboxPoll = ExpeditedMailboxPollGate()
    private val mailboxSignalRetries = SignalQueueRetryTracker()
    private val reconnectGate = ReconnectAttemptGate()
    private val historyUploadInFlight = AtomicBoolean(false)
    private var counterStore: EncryptedSignalProtocolStore? = null
    private var pollingStarted = false
    private var relayRefresh: ScheduledFuture<*>? = null
    private var transmitTimeout: ScheduledFuture<*>? = null
    private var historyPlayback: java.util.concurrent.Future<*>? = null
    @Volatile private var lastChannelMetadataRefreshMs = 0L
    @Volatile private var cachedChannelDevices: List<ChannelDevice> = emptyList()
    @Volatile private var cachedDevicesChannelId: String? = null
    @Volatile private var cachedDevicesMembershipEpoch: Int? = null
    private var preparedMediaEpoch: PreparedMediaEpoch? = null
    @Volatile private var reconnectAttempt: ScheduledFuture<*>? = null
    @Volatile private var historyUploadRetryNotBeforeMs = 0L
    @Volatile private var historyUploadBackoffMs = 30_000L
    private lateinit var mediaSession: MediaSession
    private lateinit var hardwarePtt: HardwarePttRouter
    private var overlayButton: Button? = null
    private var foregroundTypes = 0
    @Volatile private var revocationHandled = false
    private var callEvents: CallEventStream? = null
    private val hardwareFloor =
        object : FloorController {
            private val mutableState = MutableStateFlow<FloorState>(FloorState.Idle)
            override val state: StateFlow<FloorState> = mutableState

            override fun pttDown(target: TalkTarget, mode: PttMode) {
                val channel = target.channelSummary() ?: return
                mutableState.value = FloorState.Requesting(target, mode)
                worker.execute { beginTransmit(channel) }
            }

            override fun pttUp(target: TalkTarget) {
                mutableState.value = FloorState.Idle
                worker.execute { endTransmit() }
            }

            override fun requestSos(target: TalkTarget, silent: Boolean) {
                val channel = target.channelSummary() ?: return
                mutableState.value = FloorState.Sos(UUID.randomUUID(), silent, System.currentTimeMillis() + 30_000)
                worker.execute { beginTransmit(channel, sos = true, silent = silent) }
            }

            override fun setVoxEnabled(enabled: Boolean) = Unit
            override fun setDirectPeerPresence(aci: app.ptt.crypto.Aci, presence: PeerPresence) = Unit

            private fun TalkTarget.channelSummary(): ChannelSummary? {
                val selected = activeChannel ?: return null
                return if (this is TalkTarget.Channel && id.uuid.toString() == selected.channelId) selected else null
            }
        }

    override fun onCreate() {
        super.onCreate()
        running = true
        audio = AndroidAudioEngine(
            this,
            syntheticCapture = BuildConfig.DEBUG &&
                getSharedPreferences(DEBUG_E2E_PREFS, MODE_PRIVATE).getBoolean(DEBUG_E2E_SYNTHETIC_CAPTURE, false),
        )
        hardwarePtt =
            HardwarePttRouter(
                hardwareFloor,
                target = {
                    activeChannel?.let { TalkTarget.Channel(ChannelId(UUID.fromString(it.channelId))) }
                },
                audit = { event ->
                    broadcast(
                        STATE_HARDWARE,
                        "${event.source.name.lowercase()} ${event.action} ${if (event.accepted) "accepted" else "ignored"}",
                    )
                },
            )
        mediaSession = MediaSession(this, "PTT Talk hardware input")
        mediaSession.setCallback(
            object : MediaSession.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val event =
                        if (Build.VERSION.SDK_INT >= 33) {
                            mediaButtonIntent.getParcelableExtra(EXTRA_KEY_EVENT, KeyEvent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            mediaButtonIntent.getParcelableExtra(EXTRA_KEY_EVENT)
                        } ?: return false
                    if (event.keyCode !in HARDWARE_KEY_CODES || event.repeatCount != 0) return false
                    return hardwarePtt.button(
                        hardwareSource(event),
                        event.action == KeyEvent.ACTION_DOWN,
                    )
                }
            },
        )
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
                .setState(PlaybackState.STATE_PAUSED, 0, 0f)
                .build(),
        )
        mediaSession.isActive = true
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
        val startupType = when {
            foregroundTypes != 0 -> foregroundTypes
            intent?.action == ACTION_ARM -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            else -> {
                // A high-priority FCM voice wake and a system START_STICKY restore are
                // background starts. They may receive and play media, but Android 14+
                // forbids acquiring a while-in-use microphone foreground type here.
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            }
        }
        if (!ensureForegroundType(startupType, intent?.action == ACTION_PUSH_WAKE)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        initializeSession()
        when (intent?.action) {
            ACTION_ARM -> {
                val requestedChannel = intent.channel()
                if (requestedChannel != null) {
                    worker.execute { prepareChannel(requestedChannel) }
                } else if (activeChannel == null) {
                    worker.execute { prepareRestoredChannel() }
                }
            }
            ACTION_PUSH_WAKE -> {
                if (activeChannel == null) {
                    worker.execute { prepareRestoredChannel() }
                }
            }
            ACTION_PREPARE -> intent.channel()?.let { channel -> worker.execute { prepareChannel(channel) } }
            ACTION_BEGIN_TRANSMIT -> intent.channel()?.let { channel ->
                val sos = intent.getBooleanExtra(EXTRA_SOS, false)
                val silent = intent.getBooleanExtra(EXTRA_SILENT, false)
                if (activeChannel?.channelId != channel.channelId) {
                    broadcast(STATE_ERROR, "Select and prepare the channel before transmitting.")
                } else if (CallSessionService.isActive() && !sos) {
                    broadcast(STATE_DENIED, "Push to Talk is unavailable during a call.")
                } else if (CallSessionService.isActive()) {
                    broadcast(STATE_PREPARING, "Ending the call for priority SOS…")
                    CallSessionService.preemptForSos(this)
                    scheduler.schedule(
                        {
                            if (ensureMicrophoneForeground()) {
                                hardwarePtt.sos(HardwarePttSource.SCREEN, silent)
                            } else {
                                broadcast(
                                    STATE_DENIED,
                                    "Open PTT Talk before transmitting so Android can enable the microphone.",
                                )
                            }
                        },
                        400, TimeUnit.MILLISECONDS,
                    )
                } else if (!ensureMicrophoneForeground()) {
                    broadcast(STATE_DENIED, "Open PTT Talk before transmitting so Android can enable the microphone.")
                } else if (sos) {
                    hardwarePtt.sos(HardwarePttSource.SCREEN, silent)
                } else {
                    hardwarePtt.button(HardwarePttSource.SCREEN, true)
                }
            }
            ACTION_END_TRANSMIT -> hardwarePtt.button(HardwarePttSource.SCREEN, false)
            ACTION_CALL_AUDIO_STARTED -> worker.execute { suspendForCallAudio() }
            ACTION_CALL_AUDIO_ENDED -> worker.execute {
                if (!CallSessionService.isActive()) {
                    discardSuppressedIncoming()
                    broadcast(STATE_READY, activeChannel?.let { "${it.displayName} ready." } ?: "Push to Talk ready.")
                    activateNextIncomingPlayback()
                }
            }
            ACTION_PLAY_HISTORY -> intent.getStringExtra(EXTRA_TALK_ID)?.let { talkId ->
                worker.execute { playHistory(talkId) }
            }
            ACTION_HARDWARE_BUTTON -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                val pressed = intent.getBooleanExtra(EXTRA_PRESSED, false)
                if (CallSessionService.isActive()) {
                    broadcast(STATE_DENIED, "Hardware Push to Talk is unavailable during a call.")
                } else if (pressed && !ensureMicrophoneForeground()) {
                    broadcast(STATE_DENIED, "Open PTT Talk before transmitting so Android can enable the microphone.")
                } else hardwarePtt.button(source, pressed)
            }
            ACTION_HARDWARE_TOGGLE -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                val pressed = !hardwarePtt.isHeld(source)
                if (pressed && !ensureMicrophoneForeground()) {
                    broadcast(STATE_DENIED, "Open PTT Talk before transmitting so Android can enable the microphone.")
                } else {
                    hardwarePtt.button(source, pressed)
                }
            }
            ACTION_HARDWARE_SOS -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                if (CallSessionService.isActive()) {
                    CallSessionService.preemptForSos(this)
                    scheduler.schedule(
                        {
                            if (ensureMicrophoneForeground()) {
                                hardwarePtt.sos(source, intent.getBooleanExtra(EXTRA_SILENT, false))
                            } else {
                                broadcast(
                                    STATE_DENIED,
                                    "Open PTT Talk before transmitting so Android can enable the microphone.",
                                )
                            }
                        },
                        400, TimeUnit.MILLISECONDS,
                    )
                } else if (!ensureMicrophoneForeground()) {
                    broadcast(STATE_DENIED, "Open PTT Talk before transmitting so Android can enable the microphone.")
                } else hardwarePtt.sos(source, intent.getBooleanExtra(EXTRA_SILENT, false))
            }
            ACTION_OVERLAY_ENABLE -> showOverlay()
            ACTION_OVERLAY_DISABLE -> hideOverlay()
            ACTION_SET_PRESENCE -> worker.execute { heartbeatPresence() }
            else -> Unit
        }
        setArmed(this, true)
        return START_STICKY
    }

    private fun ensureMicrophoneForeground(): Boolean =
        ensureForegroundType(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, pushWake = false)

    private fun ensureForegroundType(requestedType: Int, pushWake: Boolean): Boolean {
        val requestedTypes = foregroundTypes or requestedType
        if (requestedTypes == foregroundTypes) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
            return true
        }
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification(), requestedTypes)
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
            foregroundTypes = requestedTypes
        }.fold(
            onSuccess = { true },
            onFailure = { error ->
                Log.w("PTT_SESSION", "Android denied foreground audio access", error)
                if (pushWake && BuildConfig.DEBUG) {
                    runCatching { File(filesDir, "ptt-e2e-push-playback-state.txt").writeText("fail:foreground") }
                }
                false
            },
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun suspendForCallAudio() {
        endTransmit()
        val discarded = mutableListOf<IncomingVoiceStream>()
        synchronized(incoming) {
            val normalTalkIds = incoming.filterValues { !it.isSos }.keys
            normalTalkIds.forEach { talkId ->
                incoming.remove(talkId)?.let(discarded::add)
                incomingReadyForPlayback -= talkId
                incomingSuppressedByCall -= talkId
                if (activeIncomingTalkId == talkId) activeIncomingTalkId = null
            }
        }
        discarded.forEach(IncomingVoiceStream::close)
        // Relinquish capture, playback, audio focus, Bluetooth and communication mode.
        // Android Core-Telecom exclusively owns those resources until the call ends.
        audio.close()
        broadcast(STATE_DENIED, "Push to Talk is unavailable during the call.")
    }

    override fun onDestroy() {
        running = false
        runCatching { endTransmit() }
        relay?.close()
        relay = null
        relayRefresh?.cancel(false)
        relayRefresh = null
        cancelChannelReconnect()
        historyPlayback?.cancel(true)
        historyPlayback = null
        synchronized(incoming) {
            incoming.values.forEach(IncomingVoiceStream::close)
            incoming.clear()
            activeIncomingTalkId = null
            incomingReadyForPlayback.clear()
            incomingSuppressedByCall.clear()
            sosPreemptionScheduled.clear()
            pendingMedia.clear()
        }
        counterStore?.close()
        counterStore = null
        worker.shutdownNow()
        scheduler.shutdownNow()
        audio.close()
        mediaSession.isActive = false
        mediaSession.release()
        hideOverlay()
        callEvents?.close()
        callEvents = null
        super.onDestroy()
    }

    private fun showOverlay() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !Settings.canDrawOverlays(this)) {
            broadcast(STATE_ERROR, "Allow Display over other apps before enabling floating PTT.")
            return
        }
        if (overlayButton != null) return
        val button = Button(this).apply {
            text = "PTT"
            alpha = 0.9f
            minWidth = 160
            minHeight = 160
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> hardwarePtt.button(HardwarePttSource.OVERLAY, true)
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                        hardwarePtt.button(HardwarePttSource.OVERLAY, false)
                    else -> false
                }
            }
        }
        val params =
            WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.END or Gravity.CENTER_VERTICAL
                x = 24
            }
        runCatching { getSystemService(WindowManager::class.java).addView(button, params) }
            .onSuccess {
                overlayButton = button
                setOverlayEnabled(this, true)
                broadcast(STATE_HARDWARE, "Floating hold-to-talk enabled")
            }
            .onFailure { broadcast(STATE_ERROR, "Could not show floating PTT: ${it.message}") }
    }

    private fun hideOverlay() {
        overlayButton?.let { button ->
            hardwarePtt.disconnect(HardwarePttSource.OVERLAY)
            runCatching { getSystemService(WindowManager::class.java).removeView(button) }
        }
        overlayButton = null
        setOverlayEnabled(this, false)
    }

    private fun initializeSession() {
        if (!pollingStarted) {
            pollingStarted = true
            SecureDeviceStore(this).load()?.let { session ->
                callEvents = CallEventStream(session) { event ->
                    worker.execute { handleCallCoordinationEvent(session, event) }
                }.also { it.start() }
            }
            PttMessagingService.registerCurrentInstallation(this)
            scheduler.execute {
                val session = SecureDeviceStore(this).load() ?: return@execute
                runCatching { PersistentPairwiseCrypto(this, session).ensurePreKeysPublished() }
                    .onFailure { handleServiceFailure(it, "Prekey publication failed") }
            }
            scheduler.scheduleWithFixedDelay(
                { scheduleMailboxDelivery() },
                250,
                250,
                TimeUnit.MILLISECONDS,
            )
            scheduler.scheduleWithFixedDelay(
                {
                    runCatching { syncHistory() }.onFailure { error ->
                        if (!HistoryUploadFailurePolicy.shouldDefer(error)) {
                            handleServiceFailure(error, "History sync failed")
                        }
                    }
                },
                2,
                2,
                TimeUnit.SECONDS,
            )
            scheduler.scheduleWithFixedDelay(
                { runCatching { heartbeatPresence() }.onFailure { handleServiceFailure(it, "Presence update failed") } },
                0,
                30,
                TimeUnit.SECONDS,
            )
        }
    }

    private fun handleCallCoordinationEvent(session: DeviceSession, event: CallCoordinationEvent) {
        if (event.type == "ringing") {
            if (!CallSessionService.isActive()) CallSessionService.incoming(this, event.callId)
            return
        }
        val snapshot = CallSessionService.snapshot()
        if (!snapshot.active || !snapshot.callId.equals(event.callId, true)) return
        runCatching { ControlApi(session.serverUrl).call(session, event.callId) }.onSuccess { call ->
            val participant = call.participants.firstOrNull { it.aci.equals(session.aci, true) }
            when {
                call.state == "ended" -> CallSessionService.remoteEnd(this, event.callId)
                participant?.claimedDeviceId != null && participant.claimedDeviceId != session.deviceId ->
                    CallSessionService.answeredElsewhere(this, event.callId)
            }
        }
    }

    private fun heartbeatPresence() {
        val session = SecureDeviceStore(this).load() ?: return
        val mode = presenceMode(this)
        ControlApi(session.serverUrl).setPresence(session, mode)
        broadcast(STATE_PRESENCE, "Mode: ${mode.replaceFirstChar { it.uppercase() }}")
    }

    private fun prepareChannel(channel: ChannelSummary) {
        val session = SecureDeviceStore(this).load() ?: return
        broadcast(STATE_PREPARING, "Preparing ${channel.displayName} securely…")
        runCatching {
            if (outgoing != null || heldFloorToken != null) {
                endTransmit()
            }
            relay?.close()
            relayRefresh?.cancel(false)
            relayRefresh = null
            preparedMediaEpoch = null
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            synchronized(incoming) {
                incoming.values.forEach(IncomingVoiceStream::close)
                incoming.clear()
                activeIncomingTalkId = null
                incomingReadyForPlayback.clear()
                incomingSuppressedByCall.clear()
                sosPreemptionScheduled.clear()
                pendingMedia.clear()
            }
            val api = ControlApi(session.serverUrl)
            val credential = api.relayCredential(session, channel.channelId)
            val devices = api.channelDevices(session, channel.channelId)
            val supportsFastFloor = api.supportsCapability("media-floor-control-v1")
            val connected =
                AdaptiveMediaRelay.connect(
                    session.serverUrl,
                    session.accessToken,
                    channel.channelId,
                    credential.relayAddress,
                    credential.ticket,
                    credential.senderDemux,
                    supportsFastFloor,
                    ::onMedia,
                    { error -> handleServiceFailure(error, "Relay connection interrupted") },
                    { detail ->
                        cancelChannelReconnect()
                        broadcast(STATE_READY, detail)
                    },
                )
            activeChannel = channel
            persistChannel(this, channel)
            lastChannelMetadataRefreshMs = System.currentTimeMillis()
            cachedChannelDevices = devices
            cachedDevicesChannelId = channel.channelId
            cachedDevicesMembershipEpoch = channel.membershipEpoch
            relayCredential = credential
            relay = connected
            scheduleRelayRefresh(channel, credential)
            if (channel.role != "listen") {
                preparedMediaEpoch = prepareMediaEpoch(session, channel, credential, devices, 30_000, false)
            }
            cancelChannelReconnect()
            broadcast(
                STATE_READY,
                if (channel.role == "listen") "Listening to ${channel.displayName}; your role cannot transmit."
                else "${channel.displayName} is ready. Hold the button to request the floor.",
            )
        }.onFailure { error ->
            relayCredential = null
            relay = null
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            if (CommunicationEstablishmentPolicy.isTransientNetworkFailure(error)) {
                activeChannel = channel
                handleServiceFailure(error, "Channel connection interrupted")
                scheduleChannelReconnect(channel)
            } else {
                activeChannel = null
                handleServiceFailure(error, "Channel preparation failed")
            }
        }
    }

    private fun prepareRestoredChannel() {
        val persisted = restoredChannel(this) ?: return
        val session = SecureDeviceStore(this).load() ?: return
        runCatching {
            ControlApi(session.serverUrl).channels(session)
                .firstOrNull { it.channelId == persisted.channelId }
                ?: error("The previously selected channel is no longer available.")
        }.onSuccess(::prepareChannel)
            .onFailure { handleServiceFailure(it, "Could not restore the selected channel") }
    }

    private fun scheduleRelayRefresh(channel: ChannelSummary, credential: RelayCredential) {
        relayRefresh?.cancel(false)
        val delayMillis =
            (credential.expiresAt.toEpochMilli() - java.time.Instant.now().toEpochMilli() - 60_000)
                .coerceAtLeast(1_000)
        relayRefresh =
            scheduler.schedule(
                { worker.execute { refreshRelay(channel.channelId) } },
                delayMillis,
                TimeUnit.MILLISECONDS,
            )
    }

    private fun refreshRelay(channelId: String) {
        val channel = activeChannel?.takeIf { it.channelId == channelId } ?: return
        if (outgoing != null || heldFloorToken != null) {
            relayRefresh = scheduler.schedule({ worker.execute { refreshRelay(channelId) } }, 5, TimeUnit.SECONDS)
            return
        }
        val session = SecureDeviceStore(this).load() ?: return
        runCatching {
            val api = ControlApi(session.serverUrl)
            val issued = api.relayCredential(session, channelId)
            val supportsFastFloor = api.supportsCapability("media-floor-control-v1")
            val connected =
                AdaptiveMediaRelay.connect(
                    session.serverUrl,
                    session.accessToken,
                    channelId,
                    issued.relayAddress,
                    issued.ticket,
                    issued.senderDemux,
                    supportsFastFloor,
                    ::onMedia,
                    { error -> handleServiceFailure(error, "Relay connection interrupted") },
                    { detail ->
                        cancelChannelReconnect()
                        broadcast(STATE_READY, detail)
                    },
                )
            if (activeChannel?.channelId != channelId || outgoing != null || heldFloorToken != null) {
                connected.close()
                return
            }
            val previous = relay
            relay = connected
            relayCredential = issued
            preparedMediaEpoch = null
            previous?.close()
            scheduleRelayRefresh(channel, issued)
            if (channel.role != "listen") {
                val devices = channelDevicesForTransmit(session, api, channel)
                preparedMediaEpoch = prepareMediaEpoch(session, channel, issued, devices, 30_000, false)
            }
            broadcast(STATE_READY, "${channel.displayName} relay security refreshed.")
        }.onFailure { error ->
            handleServiceFailure(error, "Relay credential refresh failed")
            if (!revocationHandled) {
                relayRefresh = scheduler.schedule({ worker.execute { refreshRelay(channelId) } }, 10, TimeUnit.SECONDS)
            }
        }
    }

    private fun beginTransmit(channel: ChannelSummary, sos: Boolean = false, silent: Boolean = false) {
        if (activeChannel?.channelId != channel.channelId || relay == null || relayCredential == null) {
            prepareChannel(channel)
        }
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        // The authenticated floor endpoint independently validates membership,
        // role, relay lease, and epoch. Stay on the prepared hot path and only
        // refresh metadata if the server reports that our epoch is stale.
        var currentChannel = activeChannel ?: return
        if (currentChannel.role == "listen") {
            broadcast(STATE_DENIED, "Your channel role cannot transmit.")
            return
        }
        var credential = relayCredential ?: return
        var connected = relay ?: return
        if (outgoing != null || heldFloorToken != null) return
        val establishmentStartedAt = SystemClock.elapsedRealtime()
        broadcast(STATE_REQUESTING, "Waiting for an authenticated floor grant…")
        runCatching {
            val requestToken =
                Base64.encodeToString(
                    ByteArray(16).also(secureRandom::nextBytes),
                    Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
                )
            var usedFastFloor = false
            val grant =
                try {
                    val fastGrant =
                        runCatching {
                            connected.requestFloor(
                                requestToken,
                                currentChannel.membershipEpoch,
                                if (silent) 1_000 else 30_000,
                                sos,
                            )
                        }.getOrNull()
                    fastGrant?.let {
                        usedFastFloor = true
                        FloorGrant(it.granted, it.requestToken, it.grantedTotMs, it.reason)
                    } ?: api.requestFloor(
                        session, currentChannel, credential, requestToken,
                        requestedTotMs = if (silent) 1_000 else 30_000, sos = sos,
                    )
                } catch (error: ControlApiException) {
                    if (!CommunicationEstablishmentPolicy.requiresMetadataRefresh(error.status, error.code)) throw error
                    currentChannel = refreshChannelMetadata(session, api, force = true) ?: return
                    credential = checkNotNull(relayCredential) { "encrypted relay did not refresh" }
                    connected = checkNotNull(relay) { "encrypted relay did not reconnect" }
                    api.requestFloor(
                        session,
                        currentChannel,
                        credential,
                        requestToken,
                        requestedTotMs = if (silent) 1_000 else 30_000,
                        sos = sos,
                    )
                }
            Log.i("PTT_VOICE_LATENCY", "floor_path=${if (usedFastFloor) "media-socket" else "rest-fallback"}")
            if (!grant.granted) {
                broadcast(STATE_DENIED, grant.reason ?: "Channel busy. Try again in a moment.")
                return
            }
            heldFloorToken = grant.requestToken
            val floorLatencyMs = SystemClock.elapsedRealtime() - establishmentStartedAt
            Log.i(
                "PTT_VOICE_LATENCY",
                "floor_grant_latency_ms=$floorLatencyMs",
            )
            broadcast(
                STATE_GRANTED,
                if (sos && silent) "Silent SOS floor granted. Securing delivery…"
                else "Authenticated floor granted. Securing this transmission…",
                floorLatencyMs,
            )
            val devices = channelDevicesForTransmit(session, api, currentChannel)
            val announcement = takePreparedMediaEpoch(currentChannel, credential, grant.grantedTotMs, sos)
                ?: prepareMediaEpoch(
                    session,
                    currentChannel,
                    credential,
                    devices,
                    grant.grantedTotMs,
                    sos,
                ).announcement
            if (!silent && !hardwarePtt.isAnyHeld()) {
                endTransmit()
                return
            }
            val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
            synchronized(outgoingPackets) { outgoingPackets.clear() }
            outgoingAnnouncement = announcement
            outgoingStartedAt = Instant.now()
            val debugMediaStarted = AtomicBoolean(false)
            val stream =
                OutgoingVoiceStream(
                    audio,
                    connected,
                    credential.demuxToken.base64UrlBytes(),
                    announcement,
                    SqlCipherSFrameCounterStore(store, "${currentChannel.channelId}/${session.deviceId}"),
                    onPacketSent = { packet ->
                        synchronized(outgoingPackets) {
                            if (outgoingPackets.size < 1_501) outgoingPackets += packet
                        }
                    },
                    onMediaStarted = {
                        if (BuildConfig.DEBUG && debugMediaStarted.compareAndSet(false, true)) {
                            // The physical driver uses a separate action so its stable session
                            // state and production UI are not changed by test instrumentation.
                            sendBroadcast(Intent(ACTION_DEBUG_MEDIA_STARTED).setPackage(packageName))
                        }
                    },
                ) { error ->
                    broadcast(STATE_ERROR, error.message ?: "Voice transmission failed")
                    worker.execute { endTransmit() }
                }
            outgoing = stream
            if (!silent) stream.start()
            val readyLatencyMs = SystemClock.elapsedRealtime() - establishmentStartedAt
            Log.i(
                "PTT_VOICE_LATENCY",
                "communication_ready_latency_ms=$readyLatencyMs",
            )
            broadcast(
                STATE_TRANSMITTING,
                if (sos && silent) "Silent SOS sent to ${channel.displayName}."
                else if (sos) "Priority SOS floor granted to ${channel.displayName}."
                else "Encrypted floor granted for up to ${grant.grantedTotMs / 1000} seconds.",
                readyLatencyMs,
            )
            transmitTimeout?.cancel(false)
            transmitTimeout =
                scheduler.schedule(
                    {
                        worker.execute {
                            // A timeout belongs to one authenticated floor lease. A stale
                            // timeout from an earlier press must never terminate a later talk.
                            if (heldFloorToken == grant.requestToken) endTransmit()
                        }
                    },
                    grant.grantedTotMs.toLong(),
                    TimeUnit.MILLISECONDS,
                )
            if (silent) endTransmit()
        }.onFailure { error ->
            handleServiceFailure(error, "Could not start transmission")
            endTransmit()
        }
    }

    private fun endTransmit() {
        transmitTimeout?.cancel(false)
        transmitTimeout = null
        hardwarePtt.reset()
        outgoing?.close()
        outgoing = null
        val announcement = outgoingAnnouncement
        val startedAt = outgoingStartedAt
        val packets = synchronized(outgoingPackets) { outgoingPackets.map(ByteArray::copyOf).also { outgoingPackets.clear() } }
        outgoingAnnouncement = null
        outgoingStartedAt = null
        val token = heldFloorToken
        heldFloorToken = null
        val channel = activeChannel
        val session = SecureDeviceStore(this).load()
        if (token != null && channel != null && session != null) {
            runCatching {
                // On TLS, release shares the media WebSocket. Its acknowledgement proves
                // the queued encrypted END frame was relayed before authorization is removed.
                val orderedRelease = runCatching { relay?.releaseFloor(token) }
                    .onFailure { Log.w("PTT_VOICE", "ordered floor release unavailable", it) }
                    .getOrNull()
                if (orderedRelease == null) {
                    ControlApi(session.serverUrl).releaseFloor(session, channel.channelId, token)
                }
            }
                .onFailure { handleServiceFailure(it, "Floor release failed") }
        }
        if (announcement != null && startedAt != null && packets.isNotEmpty() && session != null) {
            runCatching {
                val ciphertext =
                    EncryptedHistory.seal(
                        announcement.channelId,
                        announcement.talkId,
                        announcement.membershipEpoch,
                        announcement.kid,
                        announcement.baseKey,
                        packets,
                    )
                val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
                store.stageHistoryUpload(
                    announcement.talkId.toString(),
                    startedAt.toEpochMilli(),
                    (packets.size * 20).coerceAtMost(30_000),
                    ciphertext,
                )
                scheduler.execute {
                    runCatching { uploadPendingHistory(session, store, ControlApi(session.serverUrl)) }
                        .onFailure { error ->
                            if (HistoryUploadFailurePolicy.shouldDefer(error)) {
                                deferHistoryUpload()
                            } else {
                                handleServiceFailure(error, "Encrypted history upload failed")
                            }
                        }
                }
            }.onFailure { handleServiceFailure(it, "Encrypted history save failed") }
        }
        if (channel != null && session != null && channel.role != "listen") {
            // Do the expensive per-device Signal fan-out while the channel is visibly
            // finalizing. Once READY is emitted, the next press can proceed directly from
            // its authenticated floor grant to capture instead of making the user hold
            // through one to three seconds of key distribution.
            runCatching {
                val current = activeChannel?.takeIf { it.channelId == channel.channelId } ?: return@runCatching
                val credential = relayCredential ?: return@runCatching
                val api = ControlApi(session.serverUrl)
                val devices = channelDevicesForTransmit(session, api, current)
                preparedMediaEpoch = prepareMediaEpoch(session, current, credential, devices, 30_000, false)
            }.onFailure { Log.w("PTT_VOICE_LATENCY", "media epoch prewarm failed", it) }
        }
        if (channel != null) broadcast(STATE_READY, "${channel.displayName} ready.")
    }

    private fun pollMailbox() {
        val pollStartedAtMs = SystemClock.elapsedRealtime()
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        val channel = refreshChannelMetadata(session, api) ?: return
        val items = api.mailboxItems(session, 25)
        val pollDurationMs = SystemClock.elapsedRealtime() - pollStartedAtMs
        if (BuildConfig.DEBUG && (items.isNotEmpty() || MailboxDeliveryTimingPolicy.isSlow(pollDurationMs))) {
            Log.i(
                "PTT_MEDIA",
                "RX_MAILBOX_POLL items=${items.size} duration_ms=$pollDurationMs",
            )
        }
        if (items.isEmpty()) return
        // Membership changes invalidate this cache. Reusing the authenticated device directory
        // avoids placing another serial control-plane round trip on the live receive path.
        val devices = channelDevicesForTransmit(session, api, channel)
        val crypto = PersistentPairwiseCrypto(this, session)
        val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
        val accepted = mutableListOf<String>()
        val newlyReadyTalks = mutableListOf<UUID>()
        for (item in items) {
            try {
                val opened = crypto.decryptEnvelope(
                    item.envelope,
                    devices,
                    UUID.fromString(channel.distributionId),
                    store,
                )
                val announcement = opened.announcement
                if (announcement.channelId.toString() == channel.channelId &&
                    announcement.membershipEpoch == channel.membershipEpoch
                ) {
                        store.putHistoryEpoch(
                            EncryptedHistoryRecord(
                                talkId = announcement.talkId.toString(),
                                channelId = announcement.channelId.toString(),
                                membershipEpoch = announcement.membershipEpoch,
                                mediaKid = announcement.kid.toString(),
                                baseKey = announcement.baseKey,
                                senderAci = opened.senderAci,
                                senderDeviceId = opened.senderDeviceId,
                                announcedAtMs = System.currentTimeMillis(),
                                objectId = null,
                                startedAtMs = null,
                                durationMs = null,
                                expiresAtMs = null,
                                ciphertext = null,
                                isSos = announcement.isSos,
                            ),
                        )
                        val callAudioDecision = PttCallAudioPriorityPolicy.decide(
                            callActive = CallSessionService.isActive(),
                            isSos = announcement.isSos,
                        )
                        // The authenticated control announcement normally arrives before its
                        // media packets. Use that lead time to open the output route, except while
                        // Core-Telecom exclusively owns audio for a normal call.
                        if (callAudioDecision == PttCallAudioDecision.PLAY) audio.preparePlayback()
                        if (callAudioDecision == PttCallAudioDecision.PREEMPT_CALL) {
                            CallSessionService.preemptForSos(this)
                        }
                        val incomingStream =
                            IncomingVoiceStream(
                                audio,
                                opened.senderAci,
                                opened.senderDeviceId,
                                announcement,
                                onError = { error ->
                                    broadcast(STATE_ERROR, error.message ?: "Encrypted playout failed")
                                    // Stream callbacks already synchronize their shared maps.
                                    // Complete locally instead of queuing behind control-plane
                                    // polling, which can leave a finished talk occupying the
                                    // only speaker slot for several seconds.
                                    completeIncomingPlayback(announcement.talkId)
                                },
                                onStarted = {
                                    broadcast(
                                        STATE_RECEIVING,
                                        if (announcement.isSos) {
                                            "SOS from ${opened.senderAci.take(8)}… device ${opened.senderDeviceId} in ${channel.displayName}."
                                        } else {
                                            "Playing authenticated encrypted voice from device ${opened.senderDeviceId}."
                                        },
                                    )
                                },
                                onEnded = { stats ->
                                    if (BuildConfig.DEBUG) {
                                        Log.i(
                                            "PTT_MEDIA",
                                            "RX_END authenticated_packets=${stats.authenticatedPackets} " +
                                                "played_packets=${stats.playedPackets} " +
                                                "concealed_frames=${stats.concealedFrames}",
                                        )
                                    }
                                    broadcast(
                                        STATE_PLAYED,
                                        "Completed authenticated encrypted playback from device ${opened.senderDeviceId}.",
                                        playbackStats = stats,
                                    )
                                    completeIncomingPlayback(announcement.talkId)
                                },
                            )
                        enqueueIncomingPlayback(announcement.talkId, incomingStream)
                        newlyReadyTalks += announcement.talkId
                        if (callAudioDecision == PttCallAudioDecision.ARCHIVE_ONLY) {
                            synchronized(incoming) { incomingSuppressedByCall += announcement.talkId }
                            scheduler.schedule(
                                { worker.execute { expireSuppressedIncoming(announcement.talkId) } },
                                SUPPRESSED_INCOMING_TIMEOUT_MS,
                                TimeUnit.MILLISECONDS,
                            )
                        }
                        if (BuildConfig.DEBUG) {
                            Log.i(
                                "PTT_MEDIA",
                                "RX_KEY_READY sender_device=${opened.senderDeviceId} demux=${announcement.senderDemux}",
                            )
                        }
                        accepted += item.itemId
                } else {
                    // Stale authenticated membership traffic cannot become
                    // current and must not starve the bounded mailbox page.
                    accepted += item.itemId
                }
            } catch (error: Exception) {
                val disposition = SignalQueueFailureDisposition.classify(error)
                if (BuildConfig.DEBUG) {
                    Log.w(
                        "PTT_MEDIA",
                        "RX_KEY_REJECTED type=${error.javaClass.simpleName} disposition=$disposition",
                    )
                }
                when (disposition) {
                    SignalQueueFailureDisposition.RETRY -> {
                        // A regular message may have overtaken its prekey message. Give that
                        // race a bounded grace period, then acknowledge the immutable stale
                        // envelope so it cannot permanently hide newer sender-key announcements
                        // behind the server's bounded mailbox page.
                        if (mailboxSignalRetries.shouldAcknowledge(
                                item.itemId,
                                SystemClock.elapsedRealtime(),
                            )
                        ) {
                            if (BuildConfig.DEBUG) {
                                Log.w("PTT_MEDIA", "RX_KEY_STALE acknowledged_after_bounded_retry")
                            }
                            accepted += item.itemId
                        }
                    }
                    SignalQueueFailureDisposition.ACKNOWLEDGE -> {
                        // This immutable replay or envelope for a retired local prekey
                        // can never become decryptable and must not starve newer voice.
                        accepted += item.itemId
                    }
                    SignalQueueFailureDisposition.FAIL -> when (error) {
                        is InvalidMessageException, is IllegalArgumentException -> accepted += item.itemId
                        else -> throw error
                    }
                }
            }
        }
        if (accepted.isNotEmpty()) {
            AuthenticatedMailboxDeliveryPolicy.deliver(
                makeLocallyUsable = {
                    // The envelope and epoch are already authenticated and durable. Fill the
                    // jitter buffers before starting their workers so a large pre-key backlog
                    // cannot starve the first decoded frame on the same CPU.
                    replayPendingMedia()
                    synchronized(incoming) { incomingReadyForPlayback += newlyReadyTalks }
                    activateNextIncomingPlayback()
                    if (BuildConfig.DEBUG) Log.i("PTT_MEDIA", "RX_PLAYBACK_ELIGIBLE")
                },
                acknowledgeRemote = {
                    api.acknowledgeMailbox(session, accepted)
                    mailboxSignalRetries.resolved(accepted)
                    if (BuildConfig.DEBUG) Log.i("PTT_MEDIA", "RX_MAILBOX_ACKNOWLEDGED")
                },
            )
        }
    }

    private fun refreshChannelMetadata(
        session: DeviceSession,
        api: ControlApi,
        force: Boolean = false,
    ): ChannelSummary? {
        val selected = activeChannel ?: return null
        val now = System.currentTimeMillis()
        if (!force && now - lastChannelMetadataRefreshMs < CHANNEL_METADATA_REFRESH_MS) return selected
        val fresh = api.channels(session).firstOrNull { it.channelId == selected.channelId }
        lastChannelMetadataRefreshMs = now
        if (fresh == null) {
            activeChannel = null
            relayRefresh?.cancel(false)
            relayRefresh = null
            relay?.close()
            relay = null
            relayCredential = null
            preparedMediaEpoch = null
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            synchronized(incoming) {
                incoming.values.forEach(IncomingVoiceStream::close)
                incoming.clear()
                activeIncomingTalkId = null
                incomingReadyForPlayback.clear()
                incomingSuppressedByCall.clear()
                sosPreemptionScheduled.clear()
                pendingMedia.clear()
            }
            broadcast(STATE_DENIED, "You no longer have access to this channel.")
            return null
        }
        val rotated =
            fresh.membershipEpoch != selected.membershipEpoch ||
                fresh.distributionId != selected.distributionId ||
                fresh.role != selected.role
        activeChannel = fresh
        if (rotated) {
            preparedMediaEpoch = null
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            broadcast(STATE_PREPARING, "Channel membership changed; rotating sender keys…")
            refreshRelay(fresh.channelId)
        }
        return fresh
    }

    private fun channelDevicesForTransmit(
        session: DeviceSession,
        api: ControlApi,
        channel: ChannelSummary,
    ): List<ChannelDevice> {
        if (cachedDevicesChannelId == channel.channelId &&
            cachedDevicesMembershipEpoch == channel.membershipEpoch &&
            cachedChannelDevices.isNotEmpty()
        ) return cachedChannelDevices
        return api.channelDevices(session, channel.channelId).also { devices ->
            cachedChannelDevices = devices
            cachedDevicesChannelId = channel.channelId
            cachedDevicesMembershipEpoch = channel.membershipEpoch
        }
    }

    private fun prepareMediaEpoch(
        session: DeviceSession,
        channel: ChannelSummary,
        credential: RelayCredential,
        devices: List<ChannelDevice>,
        grantedTotMs: Int,
        isSos: Boolean,
    ): PreparedMediaEpoch {
        val announcement =
            MediaEpochAnnouncement(
                UUID.fromString(channel.channelId),
                UUID.randomUUID(),
                channel.membershipEpoch,
                credential.senderDemux,
                generateSequence { secureRandom.nextLong().toULong() }.first { it != 0uL },
                ByteArray(32).also(secureRandom::nextBytes),
                grantedTotMs,
                isSos,
            )
        val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
        PersistentPairwiseCrypto(this, session).announceMediaEpoch(
            devices,
            UUID.fromString(channel.distributionId),
            announcement,
            store,
        )
        store.putHistoryEpoch(
            EncryptedHistoryRecord(
                talkId = announcement.talkId.toString(),
                channelId = announcement.channelId.toString(),
                membershipEpoch = announcement.membershipEpoch,
                mediaKid = announcement.kid.toString(),
                baseKey = announcement.baseKey,
                senderAci = session.aci,
                senderDeviceId = session.deviceId,
                announcedAtMs = System.currentTimeMillis(),
                objectId = null,
                startedAtMs = null,
                durationMs = null,
                expiresAtMs = null,
                ciphertext = null,
                isSos = announcement.isSos,
            ),
        )
        return PreparedMediaEpoch(
            channel.channelId,
            channel.membershipEpoch,
            channel.distributionId,
            credential.senderDemux,
            grantedTotMs,
            isSos,
            announcement,
        )
    }

    private fun takePreparedMediaEpoch(
        channel: ChannelSummary,
        credential: RelayCredential,
        grantedTotMs: Int,
        isSos: Boolean,
    ): MediaEpochAnnouncement? {
        val prepared = preparedMediaEpoch ?: return null
        if (!CommunicationEstablishmentPolicy.matchesPreparedMediaEpoch(
                prepared.channelId,
                prepared.membershipEpoch,
                prepared.distributionId,
                prepared.senderDemux,
                prepared.grantedTotMs,
                prepared.isSos,
                channel,
                credential.senderDemux,
                grantedTotMs,
                isSos,
            )
        ) {
            // A floor grant or membership/relay change can invalidate a prepared epoch.
            // Never retain mismatched key material for a later transmission.
            preparedMediaEpoch = null
            return null
        }
        preparedMediaEpoch = null
        return prepared.announcement
    }

    private fun syncHistory() {
        val channel = activeChannel ?: return
        val session = SecureDeviceStore(this).load() ?: return
        val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
        val api = ControlApi(session.serverUrl)
        if (!uploadPendingHistory(session, store, api)) return
        api.history(session, channel.channelId, 100).forEach { metadata ->
            val local = store.historyRecord(metadata.talkId) ?: return@forEach
            if (local.objectId != null) return@forEach
            if (local.channelId != metadata.channelId ||
                local.membershipEpoch != metadata.membershipEpoch ||
                local.mediaKid.toULong() != metadata.mediaKid
            ) return@forEach
            val downloaded = api.downloadHistory(session, metadata.objectId)
            check(downloaded.metadata == metadata) { "history metadata changed during download" }
            EncryptedHistory.open(
                downloaded.ciphertext,
                UUID.fromString(local.channelId),
                UUID.fromString(local.talkId),
                local.membershipEpoch,
                local.mediaKid.toULong(),
                local.baseKey,
            )
            store.completeHistory(
                local.talkId,
                metadata.objectId,
                metadata.startedAt.toEpochMilli(),
                metadata.durationMs,
                metadata.expiresAt.toEpochMilli(),
                downloaded.ciphertext,
            )
            broadcast(STATE_HISTORY_UPDATED, "A missed encrypted transmission is available.")
        }
    }

    private fun uploadPendingHistory(
        session: DeviceSession,
        store: EncryptedSignalProtocolStore,
        api: ControlApi,
    ): Boolean {
        val pending = store.pendingHistoryUploads()
        if (pending.isEmpty()) return true
        if (System.currentTimeMillis() < historyUploadRetryNotBeforeMs) return false
        if (!historyUploadInFlight.compareAndSet(false, true)) return true
        try {
            for (record in pending) {
                val startedAtMs = requireNotNull(record.startedAtMs)
                val durationMs = requireNotNull(record.durationMs)
                val ciphertext = requireNotNull(record.ciphertext)
                val metadata = try {
                    api.uploadHistory(
                        session,
                        record.talkId,
                        record.channelId,
                        record.membershipEpoch,
                        record.mediaKid,
                        Instant.ofEpochMilli(startedAtMs),
                        durationMs,
                        ciphertext,
                    )
                } catch (error: Throwable) {
                    if (!HistoryUploadFailurePolicy.shouldDefer(error)) throw error
                    deferHistoryUpload()
                    return false
                }
                store.completeHistory(
                    record.talkId,
                    metadata.objectId,
                    metadata.startedAt.toEpochMilli(),
                    metadata.durationMs,
                    metadata.expiresAt.toEpochMilli(),
                    ciphertext,
                )
                historyUploadRetryNotBeforeMs = 0L
                historyUploadBackoffMs = 30_000L
                broadcast(STATE_HISTORY_UPDATED, "Encrypted history saved.")
            }
            return true
        } finally {
            historyUploadInFlight.set(false)
        }
    }

    private fun deferHistoryUpload() {
        val now = System.currentTimeMillis()
        historyUploadRetryNotBeforeMs = now + historyUploadBackoffMs
        historyUploadBackoffMs = (historyUploadBackoffMs * 2).coerceAtMost(300_000L)
        broadcast(
            STATE_HISTORY_DEFERRED,
            "Encrypted history saved on this device and will retry automatically.",
        )
    }

    private fun playHistory(talkId: String) {
        if (outgoing != null || heldFloorToken != null || synchronized(incoming) { incoming.isNotEmpty() }) {
            broadcast(STATE_ERROR, "Finish the active transmission before playing history.")
            return
        }
        val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
        runCatching {
            val record = store.historyRecord(talkId) ?: error("History item is unavailable")
            val ciphertext = record.ciphertext ?: error("History item is not downloaded")
            val channelId = UUID.fromString(record.channelId)
            val mediaTalkId = UUID.fromString(record.talkId)
            val packets =
                EncryptedHistory.open(
                    ciphertext,
                    channelId,
                    mediaTalkId,
                    record.membershipEpoch,
                    record.mediaKid.toULong(),
                    record.baseKey,
                )
            val senderDemux = app.ptt.media.ProductionMediaDatagram.decode(packets.first()).header.senderDemux
            val announcement =
                MediaEpochAnnouncement(
                    channelId,
                    mediaTalkId,
                    record.membershipEpoch,
                    senderDemux,
                    record.mediaKid.toULong(),
                    record.baseKey,
                    record.durationMs ?: 30_000,
                    record.isSos,
                )
            val stream =
                IncomingVoiceStream(
                    audio,
                    record.senderAci,
                    record.senderDeviceId,
                    announcement,
                    onError = {
                        broadcast(STATE_ERROR, it.message ?: "History playback failed")
                        worker.execute { completeIncomingPlayback(announcement.talkId) }
                    },
                    onStarted = { broadcast(STATE_RECEIVING, "Playing authenticated encrypted history.") },
                    onEnded = { _ ->
                        completeIncomingPlayback(announcement.talkId)
                        broadcast(STATE_READY, "History playback finished.")
                    },
                )
            enqueueIncomingPlayback(announcement.talkId, stream)
            synchronized(incoming) { incomingReadyForPlayback += announcement.talkId }
            historyPlayback?.cancel(true)
            historyPlayback = scheduler.submit {
                packets.forEach { packet ->
                    if (Thread.currentThread().isInterrupted) return@submit
                    stream.accept(packet)
                    activateIncomingPlayback(announcement.talkId)
                    Thread.sleep(20)
                }
            }
        }.onFailure { broadcast(STATE_ERROR, it.message ?: "History playback failed") }
    }

    /**
     * A single AudioTrack is shared by live and history streams. Delayed mailbox keys can make
     * several completed talks decryptable at once after a process wake, so starting every jitter
     * worker would interleave unrelated PCM frames. Queue normal talks in arrival order and let an
     * SOS become the next stream without allowing any two streams to drive the speaker together.
     */
    private fun enqueueIncomingPlayback(talkId: UUID, stream: IncomingVoiceStream) {
        var replaced: IncomingVoiceStream? = null
        synchronized(incoming) {
            replaced = incoming.put(talkId, stream)
            incomingReadyForPlayback -= talkId
            if (activeIncomingTalkId == talkId) activeIncomingTalkId = null
        }
        replaced?.close()
    }

    private fun activateIncomingPlayback(talkId: UUID) {
        var next: IncomingVoiceStream? = null
        var preemptCall = false
        synchronized(incoming) {
            val candidate = incoming[talkId]
            when (candidate?.let {
                PttCallAudioPriorityPolicy.decide(CallSessionService.isActive(), it.isSos)
            }) {
                PttCallAudioDecision.ARCHIVE_ONLY -> {
                    incomingSuppressedByCall += talkId
                    return
                }
                PttCallAudioDecision.PREEMPT_CALL -> {
                    preemptCall = sosPreemptionScheduled.add(talkId)
                }
                else -> Unit
            }
            if (activeIncomingTalkId == null && talkId in incomingReadyForPlayback &&
                candidate?.hasAuthenticatedPackets == true && !CallSessionService.isActive()
            ) {
                activeIncomingTalkId = talkId
                next = candidate
            }
        }
        if (preemptCall) {
            broadcast(STATE_PREPARING, "Ending the call for an authenticated priority SOS…")
            CallSessionService.preemptForSos(this)
        }
        next?.start()
    }

    private fun activateNextIncomingPlayback() {
        val nextId =
            synchronized(incoming) {
                if (activeIncomingTalkId != null) return
                incoming.entries
                    .firstOrNull {
                        it.key in incomingReadyForPlayback && it.value.isSos && it.value.hasAuthenticatedPackets
                    }?.key
                    ?: incoming.entries.firstOrNull {
                        it.key in incomingReadyForPlayback && it.value.hasAuthenticatedPackets
                    }?.key
            }
        if (nextId != null) activateIncomingPlayback(nextId)
    }

    private fun completeIncomingPlayback(talkId: UUID) {
        var completed: IncomingVoiceStream? = null
        var next: IncomingVoiceStream? = null
        synchronized(incoming) {
            completed = incoming.remove(talkId)
            incomingReadyForPlayback -= talkId
            incomingSuppressedByCall -= talkId
            sosPreemptionScheduled -= talkId
            if (activeIncomingTalkId == talkId) {
                activeIncomingTalkId = null
                val nextEntry = if (CallSessionService.isActive()) null else
                    incoming.entries.firstOrNull {
                        it.key in incomingReadyForPlayback && it.value.isSos && it.value.hasAuthenticatedPackets
                    } ?: incoming.entries.firstOrNull {
                        it.key in incomingReadyForPlayback && it.value.hasAuthenticatedPackets
                    }
                if (nextEntry != null) {
                    activeIncomingTalkId = nextEntry.key
                    next = nextEntry.value
                }
            }
        }
        completed?.close()
        next?.start()
    }

    private fun expireSuppressedIncoming(talkId: UUID) {
        val shouldExpire = synchronized(incoming) { talkId in incomingSuppressedByCall }
        if (shouldExpire) completeIncomingPlayback(talkId)
    }

    private fun discardSuppressedIncoming() {
        val discarded = mutableListOf<IncomingVoiceStream>()
        synchronized(incoming) {
            incomingSuppressedByCall.toList().forEach { talkId ->
                incoming.remove(talkId)?.let(discarded::add)
                incomingReadyForPlayback -= talkId
                if (activeIncomingTalkId == talkId) activeIncomingTalkId = null
            }
            incomingSuppressedByCall.clear()
        }
        discarded.forEach(IncomingVoiceStream::close)
        if (discarded.isNotEmpty()) broadcast(
            STATE_HISTORY_DEFERRED,
            "Incoming Push to Talk was kept in encrypted history during the call.",
        )
    }

    private fun onMedia(packet: ByteArray) {
        val matched = synchronized(incoming) { incoming.entries.firstOrNull { it.value.matches(packet) } }
        if (matched == null) {
            val now = SystemClock.elapsedRealtime()
            synchronized(incoming) {
                // A media burst may overtake its encrypted mailbox key while
                // chat/attachment traffic is active. Keep a bounded pre-key
                // window and replay it as soon as the announcement opens.
                while (pendingMedia.firstOrNull()?.first?.let { now - it > 10_000 } == true) {
                    pendingMedia.removeFirst()
                }
                if (pendingMedia.size >= 1_000) pendingMedia.removeFirst()
                pendingMedia.addLast(now to packet.copyOf())
            }
            expediteMailboxDelivery()
            return
        }
        runCatching {
            matched.value.accept(packet)
            val decision = PttCallAudioPriorityPolicy.decide(
                callActive = CallSessionService.isActive(),
                isSos = matched.value.isSos,
            )
            when (decision) {
                PttCallAudioDecision.PLAY,
                PttCallAudioDecision.PREEMPT_CALL -> activateIncomingPlayback(matched.key)
                PttCallAudioDecision.ARCHIVE_ONLY -> {
                    synchronized(incoming) { incomingSuppressedByCall += matched.key }
                    if (matched.value.hasAuthenticatedEnd) {
                        broadcast(
                            STATE_HISTORY_DEFERRED,
                            "Incoming Push to Talk was kept in encrypted history during the call.",
                        )
                        completeIncomingPlayback(matched.key)
                    }
                }
            }
        }
            .onFailure { error ->
                if (error === SFrameException.Replay) {
                    // UDP may legitimately duplicate a datagram. The SFrame replay window has
                    // already rejected it, so drop it without turning a healthy talk into a
                    // user-visible session failure. Forged and stale counters still fail closed.
                    if (BuildConfig.DEBUG) Log.w("PTT_MEDIA", "Dropped replayed media datagram")
                } else {
                    broadcast(STATE_ERROR, error.message ?: "Encrypted media was rejected")
                }
            }
    }

    private fun expediteMailboxDelivery() {
        scheduleMailboxDelivery()
    }

    private fun scheduleMailboxDelivery() {
        if (!expeditedMailboxPoll.begin()) return
        val queuedAtMs = SystemClock.elapsedRealtime()
        worker.execute {
            val queueWaitMs = SystemClock.elapsedRealtime() - queuedAtMs
            if (BuildConfig.DEBUG && MailboxDeliveryTimingPolicy.isSlow(queueWaitMs)) {
                Log.w("PTT_MEDIA", "RX_MAILBOX_QUEUE_WAIT duration_ms=$queueWaitMs")
            }
            do {
                runCatching { pollMailbox() }
                    .onFailure { handleServiceFailure(it, "Mailbox delivery failed") }
            } while (expeditedMailboxPoll.finish())
        }
    }

    private fun replayPendingMedia() {
        val packets = synchronized(incoming) {
            buildList {
                while (pendingMedia.isNotEmpty()) add(pendingMedia.removeFirst().second)
            }
        }
        packets.forEach(::onMedia)
    }

    private fun hardwareSource(event: KeyEvent): HardwarePttSource {
        val name = event.device?.name.orEmpty().lowercase()
        return when {
            "bluetooth" in name || "bt" in name -> HardwarePttSource.BLUETOOTH_HID
            "usb" in name -> HardwarePttSource.USB_HID
            else -> HardwarePttSource.HEADSET
        }
    }

    private fun broadcast(
        state: String,
        detail: String,
        latencyMs: Long? = null,
        playbackStats: IncomingVoiceStats? = null,
    ) {
        if (BuildConfig.DEBUG) Log.i("PTT_SESSION_TEST", "$state $detail")
        if (BuildConfig.DEBUG && state == STATE_PLAYED && playbackStats != null) {
            recordDebugPushWakePlayback(playbackStats)
        }
        val intent =
            Intent(ACTION_STATE)
                .setPackage(packageName)
                .putExtra(EXTRA_STATE, state)
                .putExtra(EXTRA_DETAIL, detail)
        if (latencyMs != null) intent.putExtra(EXTRA_LATENCY_MS, latencyMs)
        if (playbackStats != null) {
            intent
                .putExtra(EXTRA_AUTHENTICATED_PACKETS, playbackStats.authenticatedPackets)
                .putExtra(EXTRA_PLAYED_PACKETS, playbackStats.playedPackets)
                .putExtra(EXTRA_CONCEALED_FRAMES, playbackStats.concealedFrames)
        }
        sendBroadcast(intent)
    }

    private fun recordDebugPushWakePlayback(stats: IncomingVoiceStats) {
        val prefs = getSharedPreferences(DEBUG_E2E_PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean(DEBUG_E2E_SERVICE_MARKERS, false)) return
        val stateFile = File(filesDir, "ptt-e2e-push-playback-state.txt")
        // A process woken by FCM can join the first live transmission near its end. Preserve
        // that partial encrypted audio as evidence, then wait for a complete subsequent burst.
        // Once the required count passes, later partial tails must not regress the result.
        if (stateFile.takeIf(File::isFile)?.readText()?.trim() == "pass") return
        if (stats.playedPackets < DEBUG_E2E_MIN_PLAYED_FRAMES) {
            stateFile.writeText("receiving:truncated-${stats.playedPackets}-of-${stats.authenticatedPackets}")
            return
        }
        val countFile = File(filesDir, "ptt-e2e-push-playback-count.txt")
        val count = (countFile.takeIf(File::isFile)?.readText()?.trim()?.toIntOrNull() ?: 0) + 1
        countFile.writeText(count.toString())
        val target = prefs.getInt(DEBUG_E2E_SERVICE_MARKER_TARGET, 1).coerceAtLeast(1)
        stateFile.writeText(if (count >= target) "pass" else "receiving")
    }

    private fun handleServiceFailure(error: Throwable, fallback: String) {
        if (error is ControlApiException && error.status == 401) {
            wipeRevokedDevice()
            return
        }
        if (CommunicationEstablishmentPolicy.isTransientNetworkFailure(error)) {
            broadcast(STATE_RECONNECTING, "Connection interrupted. Reconnecting securely…")
            activeChannel?.let(::scheduleChannelReconnect)
            return
        }
        broadcast(STATE_ERROR, error.message ?: fallback)
    }

    private fun scheduleChannelReconnect(channel: ChannelSummary) {
        if (!running || !reconnectGate.begin()) return
        reconnectAttempt = scheduler.schedule(
            {
                worker.execute {
                    if (running && SecureDeviceStore(this).load() != null) prepareChannel(channel)
                    reconnectAttempt = null
                    reconnectGate.finish()
                    val shouldRetry = running && relay == null && activeChannel?.channelId == channel.channelId
                    if (shouldRetry) scheduleChannelReconnect(channel)
                }
            },
            2,
            TimeUnit.SECONDS,
        )
    }

    @Synchronized
    private fun cancelChannelReconnect() {
        reconnectAttempt?.cancel(false)
        reconnectAttempt = null
        reconnectGate.finish()
    }

    @Synchronized
    private fun wipeRevokedDevice() {
        if (revocationHandled) return
        revocationHandled = true
        val credentials = SecureDeviceStore(this)
        val server = credentials.load()?.serverUrl
        setArmed(this, false)
        clearPersistedChannel(this)
        relayRefresh?.cancel(false)
        relayRefresh = null
        cancelChannelReconnect()
        relay?.close()
        relay = null
        preparedMediaEpoch = null
        counterStore?.close()
        counterStore = null
        runCatching { EncryptedSignalProtocolStore.resetLocalDeviceState(this) }
        credentials.clear()
        if (server != null) credentials.saveServer(server)
        broadcast(STATE_REVOKED, "This device was revoked. Local credentials and encryption keys were removed.")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun Intent.channel(): ChannelSummary? {
        val id = getStringExtra(EXTRA_CHANNEL_ID) ?: return null
        return ChannelSummary(
            id,
            getStringExtra(EXTRA_CHANNEL_NAME) ?: return null,
            getStringExtra(EXTRA_CHANNEL_KIND) ?: return null,
            getStringExtra(EXTRA_DISTRIBUTION_ID) ?: return null,
            getIntExtra(EXTRA_MEMBERSHIP_EPOCH, 0),
            getIntExtra(EXTRA_RETENTION_DAYS, 30),
            getStringExtra(EXTRA_ROLE) ?: return null,
        )
    }

    private fun String.base64UrlBytes(): ByteArray =
        Base64.decode(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

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
        private const val ACTION_PUSH_WAKE = "app.ptt.talk.PUSH_WAKE"
        private const val ACTION_DISARM = "app.ptt.talk.DISARM"
        private const val ACTION_PREPARE = "app.ptt.talk.PREPARE"
        private const val ACTION_BEGIN_TRANSMIT = "app.ptt.talk.BEGIN_TRANSMIT"
        private const val ACTION_END_TRANSMIT = "app.ptt.talk.END_TRANSMIT"
        private const val ACTION_PLAY_HISTORY = "app.ptt.talk.PLAY_HISTORY"
        private const val ACTION_CALL_AUDIO_STARTED = "app.ptt.talk.CALL_AUDIO_STARTED"
        private const val ACTION_CALL_AUDIO_ENDED = "app.ptt.talk.CALL_AUDIO_ENDED"
        internal const val ACTION_HARDWARE_BUTTON = "app.ptt.talk.HARDWARE_BUTTON"
        internal const val ACTION_HARDWARE_TOGGLE = "app.ptt.talk.HARDWARE_TOGGLE"
        internal const val ACTION_HARDWARE_SOS = "app.ptt.talk.HARDWARE_SOS"
        private const val ACTION_OVERLAY_ENABLE = "app.ptt.talk.OVERLAY_ENABLE"
        private const val ACTION_OVERLAY_DISABLE = "app.ptt.talk.OVERLAY_DISABLE"
        private const val ACTION_SET_PRESENCE = "app.ptt.talk.SET_PRESENCE"
        const val ACTION_STATE = "app.ptt.talk.SESSION_STATE"
        internal const val ACTION_DEBUG_MEDIA_STARTED = "app.ptt.talk.DEBUG_MEDIA_STARTED"
        const val EXTRA_STATE = "state"
        const val EXTRA_DETAIL = "detail"
        internal const val EXTRA_LATENCY_MS = "latencyMs"
        const val STATE_PREPARING = "preparing"
        const val STATE_RECONNECTING = "reconnecting"
        const val STATE_READY = "ready"
        const val STATE_REQUESTING = "requesting"
        const val STATE_GRANTED = "granted"
        const val STATE_TRANSMITTING = "transmitting"
        const val STATE_HISTORY_UPDATED = "history-updated"
        const val STATE_HISTORY_DEFERRED = "history-deferred"
        const val STATE_PRESENCE = "presence"
        const val STATE_REVOKED = "revoked"
        const val STATE_DENIED = "denied"
        const val STATE_RECEIVING = "receiving"
        const val STATE_PLAYED = "played"
        const val STATE_HARDWARE = "hardware"
        const val STATE_ERROR = "error"
        private const val EXTRA_CHANNEL_ID = "channelId"
        private const val EXTRA_CHANNEL_NAME = "channelName"
        private const val EXTRA_CHANNEL_KIND = "channelKind"
        private const val EXTRA_DISTRIBUTION_ID = "distributionId"
        private const val EXTRA_MEMBERSHIP_EPOCH = "membershipEpoch"
        private const val EXTRA_RETENTION_DAYS = "retentionDays"
        private const val EXTRA_ROLE = "role"
        private const val EXTRA_TALK_ID = "talkId"
        private const val EXTRA_SOS = "sos"
        private const val EXTRA_SILENT = "silent"
        internal const val EXTRA_HARDWARE_SOURCE = "hardwareSource"
        internal const val EXTRA_PRESSED = "pressed"
        internal const val EXTRA_AUTHENTICATED_PACKETS = "authenticatedPackets"
        internal const val EXTRA_PLAYED_PACKETS = "playedPackets"
        internal const val EXTRA_CONCEALED_FRAMES = "concealedFrames"
        private const val PREFS = "ptt-session-lifecycle-v1"
        private const val ARMED = "armed"
        private const val OVERLAY_ENABLED = "overlay-enabled"
        private const val PRESENCE_MODE = "presence-mode"
        private const val ACTIVE_CHANNEL_ID = "active-channel-id"
        private const val ACTIVE_CHANNEL_NAME = "active-channel-name"
        private const val ACTIVE_CHANNEL_KIND = "active-channel-kind"
        private const val ACTIVE_CHANNEL_DISTRIBUTION_ID = "active-channel-distribution-id"
        private const val ACTIVE_CHANNEL_MEMBERSHIP_EPOCH = "active-channel-membership-epoch"
        private const val ACTIVE_CHANNEL_RETENTION_DAYS = "active-channel-retention-days"
        private const val ACTIVE_CHANNEL_ROLE = "active-channel-role"
        private const val CHANNEL_METADATA_REFRESH_MS = 2_000L
        private const val SUPPRESSED_INCOMING_TIMEOUT_MS = 45_000L
        internal const val DEBUG_E2E_PREFS = "physical-e2e-v1"
        internal const val DEBUG_E2E_SYNTHETIC_CAPTURE = "synthetic-capture"
        internal const val DEBUG_E2E_SERVICE_MARKERS = "service-playback-markers"
        internal const val DEBUG_E2E_SERVICE_MARKER_TARGET = "service-playback-marker-target"
        // A 1.6 second synthetic hold can lose a small capture-start prefix on slower OEMs,
        // but at least 600 ms must reach the hardware playback head. This rejects the short
        // tail fragments that previously made a silent or heavily clipped run look successful.
        internal const val DEBUG_E2E_MIN_PLAYED_FRAMES = 30
        @Volatile private var running = false
        private val HARDWARE_KEY_CODES =
            setOf(
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_BUTTON_1,
                KeyEvent.KEYCODE_F1,
            )

        internal fun arm(context: Context, channel: ChannelSummary? = null) {
            val intent = Intent(context, PttSessionService::class.java).setAction(ACTION_ARM)
            context.startForegroundService(channel?.let { intent.channel(ACTION_ARM, it) } ?: intent)
        }

        internal fun wakeForVoice(context: Context) {
            context.startForegroundService(Intent(context, PttSessionService::class.java).setAction(ACTION_PUSH_WAKE))
        }

        private fun persistChannel(context: Context, channel: ChannelSummary) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(ACTIVE_CHANNEL_ID, channel.channelId)
                .putString(ACTIVE_CHANNEL_NAME, channel.displayName)
                .putString(ACTIVE_CHANNEL_KIND, channel.kind)
                .putString(ACTIVE_CHANNEL_DISTRIBUTION_ID, channel.distributionId)
                .putInt(ACTIVE_CHANNEL_MEMBERSHIP_EPOCH, channel.membershipEpoch)
                .putInt(ACTIVE_CHANNEL_RETENTION_DAYS, channel.retentionDays)
                .putString(ACTIVE_CHANNEL_ROLE, channel.role)
                .apply()
        }

        private fun restoredChannel(context: Context): ChannelSummary? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val channelId = prefs.getString(ACTIVE_CHANNEL_ID, null) ?: return null
            val distributionId = prefs.getString(ACTIVE_CHANNEL_DISTRIBUTION_ID, null) ?: return null
            if (runCatching { UUID.fromString(channelId) }.isFailure ||
                runCatching { UUID.fromString(distributionId) }.isFailure
            ) return null
            return ChannelSummary(
                channelId = channelId,
                displayName = prefs.getString(ACTIVE_CHANNEL_NAME, null) ?: return null,
                kind = prefs.getString(ACTIVE_CHANNEL_KIND, null) ?: return null,
                distributionId = distributionId,
                membershipEpoch = prefs.getInt(ACTIVE_CHANNEL_MEMBERSHIP_EPOCH, 0).takeIf { it > 0 } ?: return null,
                retentionDays = prefs.getInt(ACTIVE_CHANNEL_RETENTION_DAYS, 0).coerceAtLeast(0),
                role = prefs.getString(ACTIVE_CHANNEL_ROLE, null) ?: return null,
            )
        }

        private fun clearPersistedChannel(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .remove(ACTIVE_CHANNEL_ID)
                .remove(ACTIVE_CHANNEL_NAME)
                .remove(ACTIVE_CHANNEL_KIND)
                .remove(ACTIVE_CHANNEL_DISTRIBUTION_ID)
                .remove(ACTIVE_CHANNEL_MEMBERSHIP_EPOCH)
                .remove(ACTIVE_CHANNEL_RETENTION_DAYS)
                .remove(ACTIVE_CHANNEL_ROLE)
                .apply()
        }

        fun disarm(context: Context) {
            context.startService(Intent(context, PttSessionService::class.java).setAction(ACTION_DISARM))
        }

        internal fun prepare(context: Context, channel: ChannelSummary) {
            context.startService(Intent(context, PttSessionService::class.java).channel(ACTION_PREPARE, channel))
        }

        internal fun beginTransmit(context: Context, channel: ChannelSummary) {
            context.startService(Intent(context, PttSessionService::class.java).channel(ACTION_BEGIN_TRANSMIT, channel))
        }

        internal fun beginEmergency(context: Context, channel: ChannelSummary, silent: Boolean) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .channel(ACTION_BEGIN_TRANSMIT, channel)
                    .putExtra(EXTRA_SOS, true)
                    .putExtra(EXTRA_SILENT, silent),
            )
        }

        fun endTransmit(context: Context) {
            context.startService(Intent(context, PttSessionService::class.java).setAction(ACTION_END_TRANSMIT))
        }

        fun suspendForCall(context: Context) {
            if (isArmed(context)) context.startService(
                Intent(context, PttSessionService::class.java).setAction(ACTION_CALL_AUDIO_STARTED),
            )
        }

        fun resumeAfterCall(context: Context) {
            if (isArmed(context)) context.startService(
                Intent(context, PttSessionService::class.java).setAction(ACTION_CALL_AUDIO_ENDED),
            )
        }

        internal fun hardwareButton(
            context: Context,
            source: HardwarePttSource,
            pressed: Boolean,
        ) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .setAction(ACTION_HARDWARE_BUTTON)
                    .putExtra(EXTRA_HARDWARE_SOURCE, source.name)
                    .putExtra(EXTRA_PRESSED, pressed),
            )
        }

        internal fun toggleHardware(context: Context, source: HardwarePttSource) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .setAction(ACTION_HARDWARE_TOGGLE)
                    .putExtra(EXTRA_HARDWARE_SOURCE, source.name),
            )
        }

        internal fun hardwareSos(context: Context, source: HardwarePttSource, silent: Boolean) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .setAction(ACTION_HARDWARE_SOS)
                    .putExtra(EXTRA_HARDWARE_SOURCE, source.name)
                    .putExtra(EXTRA_SILENT, silent),
            )
        }

        internal fun setOverlay(context: Context, enabled: Boolean) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .setAction(if (enabled) ACTION_OVERLAY_ENABLE else ACTION_OVERLAY_DISABLE),
            )
        }

        internal fun setPresence(context: Context, mode: String) {
            require(mode in setOf("available", "busy", "solo", "standby"))
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(PRESENCE_MODE, mode).apply()
            if (isArmed(context)) {
                context.startService(Intent(context, PttSessionService::class.java).setAction(ACTION_SET_PRESENCE))
            }
        }

        internal fun presenceMode(context: Context): String =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(PRESENCE_MODE, "available")
                ?.takeIf { it in setOf("available", "busy", "solo", "standby") }
                ?: "available"

        internal fun isOverlayEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(OVERLAY_ENABLED, false)

        internal fun playHistory(context: Context, talkId: String) {
            context.startService(
                Intent(context, PttSessionService::class.java)
                    .setAction(ACTION_PLAY_HISTORY)
                    .putExtra(EXTRA_TALK_ID, talkId),
            )
        }

        fun isArmed(context: Context): Boolean =
            running && context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ARMED, false)

        /** Persisted user consent used only to restore the session after ordinary process death. */
        internal fun hasArmAuthorization(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ARMED, false)

        /** Android never resumes microphone-capable foreground work without a fresh user gesture. */
        @android.annotation.SuppressLint("ApplySharedPref")
        internal fun requireRearmAfterBoot(context: Context) {
            running = false
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(ARMED, false)
                .putBoolean(OVERLAY_ENABLED, false)
                .commit()
        }

        private fun setArmed(context: Context, armed: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ARMED, armed).apply()
        }

        private fun setOverlayEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(OVERLAY_ENABLED, enabled).apply()
        }

        private fun Intent.channel(action: String, value: ChannelSummary): Intent =
            setAction(action)
                .putExtra(EXTRA_CHANNEL_ID, value.channelId)
                .putExtra(EXTRA_CHANNEL_NAME, value.displayName)
                .putExtra(EXTRA_CHANNEL_KIND, value.kind)
                .putExtra(EXTRA_DISTRIBUTION_ID, value.distributionId)
                .putExtra(EXTRA_MEMBERSHIP_EPOCH, value.membershipEpoch)
                .putExtra(EXTRA_RETENTION_DAYS, value.retentionDays)
                .putExtra(EXTRA_ROLE, value.role)

        private fun Intent.hardwareSource(): HardwarePttSource? =
            getStringExtra(EXTRA_HARDWARE_SOURCE)?.let { name ->
                HardwarePttSource.entries.firstOrNull { it.name == name }
            }
    }
}
