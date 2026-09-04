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
import java.io.File
import java.security.SecureRandom
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.signal.libsignal.protocol.DuplicateMessageException
import org.signal.libsignal.protocol.InvalidMessageException
import org.signal.libsignal.protocol.NoSessionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * User-armed foreground lifetime for control, crypto, floor, and audio work.
 *
 * A boot receiver clears the persisted arm bit, and the in-process running flag also rejects stale
 * state after a force-stop. The user must tap Stay connected before background work can resume.
 */
class PttSessionService : Service() {
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
    private val pendingMedia = ArrayDeque<Pair<Long, ByteArray>>()
    private val expeditedMailboxPoll = ExpeditedMailboxPollGate()
    private val historyUploadInFlight = AtomicBoolean(false)
    private var counterStore: EncryptedSignalProtocolStore? = null
    private var pollingStarted = false
    private var relayRefresh: ScheduledFuture<*>? = null
    private var historyPlayback: java.util.concurrent.Future<*>? = null
    @Volatile private var lastChannelMetadataRefreshMs = 0L
    @Volatile private var cachedChannelDevices: List<ChannelDevice> = emptyList()
    @Volatile private var cachedDevicesChannelId: String? = null
    @Volatile private var cachedDevicesMembershipEpoch: Int? = null
    @Volatile private var historyUploadRetryNotBeforeMs = 0L
    @Volatile private var historyUploadBackoffMs = 30_000L
    private lateinit var mediaSession: MediaSession
    private lateinit var hardwarePtt: HardwarePttRouter
    private var overlayButton: Button? = null
    @Volatile private var revocationHandled = false
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification())
        }
        initializeSession()
        when (intent?.action) {
            ACTION_ARM -> {
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
                } else if (sos) {
                    hardwarePtt.sos(HardwarePttSource.SCREEN, silent)
                } else {
                    hardwarePtt.button(HardwarePttSource.SCREEN, true)
                }
            }
            ACTION_END_TRANSMIT -> hardwarePtt.button(HardwarePttSource.SCREEN, false)
            ACTION_PLAY_HISTORY -> intent.getStringExtra(EXTRA_TALK_ID)?.let { talkId ->
                worker.execute { playHistory(talkId) }
            }
            ACTION_HARDWARE_BUTTON -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                hardwarePtt.button(source, intent.getBooleanExtra(EXTRA_PRESSED, false))
            }
            ACTION_HARDWARE_TOGGLE -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                hardwarePtt.button(source, !hardwarePtt.isHeld(source))
            }
            ACTION_HARDWARE_SOS -> {
                val source = intent.hardwareSource() ?: return START_STICKY
                hardwarePtt.sos(source, intent.getBooleanExtra(EXTRA_SILENT, false))
            }
            ACTION_OVERLAY_ENABLE -> showOverlay()
            ACTION_OVERLAY_DISABLE -> hideOverlay()
            ACTION_SET_PRESENCE -> worker.execute { heartbeatPresence() }
            else -> Unit
        }
        setArmed(this, true)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        setArmed(this, false)
        runCatching { endTransmit() }
        relay?.close()
        relay = null
        relayRefresh?.cancel(false)
        relayRefresh = null
        historyPlayback?.cancel(true)
        historyPlayback = null
        synchronized(incoming) {
            incoming.values.forEach(IncomingVoiceStream::close)
            incoming.clear()
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
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            synchronized(incoming) {
                incoming.values.forEach(IncomingVoiceStream::close)
                incoming.clear()
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
                    { error -> broadcast(STATE_ERROR, error.message ?: "Relay connection failed") },
                    { detail -> broadcast(STATE_READY, detail) },
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
            broadcast(
                STATE_READY,
                if (channel.role == "listen") "Listening to ${channel.displayName}; your role cannot transmit."
                else "${channel.displayName} is ready. Hold the button to request the floor.",
            )
        }.onFailure { error ->
            activeChannel = null
            relayCredential = null
            relay = null
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            handleServiceFailure(error, "Channel preparation failed")
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
                    { error -> broadcast(STATE_ERROR, error.message ?: "Relay connection failed") },
                    { detail -> broadcast(STATE_READY, detail) },
                )
            if (activeChannel?.channelId != channelId || outgoing != null || heldFloorToken != null) {
                connected.close()
                return
            }
            val previous = relay
            relay = connected
            relayCredential = issued
            previous?.close()
            scheduleRelayRefresh(channel, issued)
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
            val talkId = UUID.randomUUID()
            val key = ByteArray(32).also(secureRandom::nextBytes)
            val kid = generateSequence { secureRandom.nextLong().toULong() }.first { it != 0uL }
            val announcement =
                MediaEpochAnnouncement(
                    UUID.fromString(currentChannel.channelId),
                    talkId,
                    currentChannel.membershipEpoch,
                    credential.senderDemux,
                    kid,
                    key,
                    grant.grantedTotMs,
                    sos,
                )
            val crypto = PersistentPairwiseCrypto(this, session)
            val devices = channelDevicesForTransmit(session, api, currentChannel)
            crypto.announceMediaEpoch(
                devices,
                UUID.fromString(currentChannel.distributionId),
                announcement,
            )
            if (!silent && !hardwarePtt.isAnyHeld()) {
                endTransmit()
                return
            }
            val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
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
            synchronized(outgoingPackets) { outgoingPackets.clear() }
            outgoingAnnouncement = announcement
            outgoingStartedAt = Instant.now()
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
            scheduler.schedule({ worker.execute { endTransmit() } }, grant.grantedTotMs.toLong(), TimeUnit.MILLISECONDS)
            if (silent) endTransmit()
        }.onFailure { error ->
            handleServiceFailure(error, "Could not start transmission")
            endTransmit()
        }
    }

    private fun endTransmit() {
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
            runCatching { ControlApi(session.serverUrl).releaseFloor(session, channel.channelId, token) }
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
        if (channel != null) broadcast(STATE_READY, "${channel.displayName} ready.")
    }

    private fun pollMailbox() {
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        val channel = refreshChannelMetadata(session, api) ?: return
        val items = api.mailboxItems(session, 25)
        if (items.isEmpty()) return
        val devices = api.channelDevices(session, channel.channelId)
        val crypto = PersistentPairwiseCrypto(this, session)
        val accepted = mutableListOf<String>()
        for (item in items) {
            try {
                val opened = crypto.decryptEnvelope(item.envelope, devices, UUID.fromString(channel.distributionId))
                val announcement = opened.announcement
                if (announcement.channelId.toString() == channel.channelId &&
                    announcement.membershipEpoch == channel.membershipEpoch
                ) {
                        val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
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
                        synchronized(incoming) {
                            incoming.remove(announcement.talkId)?.close()
                            incoming[announcement.talkId] =
                                IncomingVoiceStream(
                                    audio,
                                    opened.senderAci,
                                    opened.senderDeviceId,
                                    announcement,
                                    onError = { error ->
                                        broadcast(STATE_ERROR, error.message ?: "Encrypted playout failed")
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
                                    onEnded = {
                                        broadcast(
                                            STATE_PLAYED,
                                            "Completed authenticated encrypted playback from device ${opened.senderDeviceId}.",
                                        )
                                        worker.execute {
                                            synchronized(incoming) {
                                                incoming.remove(announcement.talkId)?.close()
                                            }
                                        }
                                    },
                                )
                        }
                        accepted += item.itemId
                } else {
                    // Stale authenticated membership traffic cannot become
                    // current and must not starve the bounded mailbox page.
                    accepted += item.itemId
                }
            } catch (_: NoSessionException) {
                // A prekey message may have been overtaken; retain this item.
            } catch (_: DuplicateMessageException) {
                accepted += item.itemId
            } catch (_: InvalidMessageException) {
                accepted += item.itemId
            } catch (_: IllegalArgumentException) {
                accepted += item.itemId
            }
        }
        if (accepted.isNotEmpty()) {
            api.acknowledgeMailbox(session, accepted)
            replayPendingMedia()
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
            cachedChannelDevices = emptyList()
            cachedDevicesChannelId = null
            cachedDevicesMembershipEpoch = null
            synchronized(incoming) {
                incoming.values.forEach(IncomingVoiceStream::close)
                incoming.clear()
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
                    onError = { broadcast(STATE_ERROR, it.message ?: "History playback failed") },
                    onStarted = { broadcast(STATE_RECEIVING, "Playing authenticated encrypted history.") },
                    onEnded = {
                        synchronized(incoming) { incoming.remove(announcement.talkId)?.close() }
                        broadcast(STATE_READY, "History playback finished.")
                    },
                )
            synchronized(incoming) { incoming[announcement.talkId] = stream }
            historyPlayback?.cancel(true)
            historyPlayback = scheduler.submit {
                packets.forEach { packet ->
                    if (Thread.currentThread().isInterrupted) return@submit
                    stream.accept(packet)
                    Thread.sleep(20)
                }
            }
        }.onFailure { broadcast(STATE_ERROR, it.message ?: "History playback failed") }
    }

    private fun onMedia(packet: ByteArray) {
        val stream = synchronized(incoming) { incoming.values.firstOrNull { it.matches(packet) } }
        if (stream == null) {
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
        runCatching { stream.accept(packet) }
            .onFailure { broadcast(STATE_ERROR, it.message ?: "Encrypted media was rejected") }
    }

    private fun expediteMailboxDelivery() {
        scheduleMailboxDelivery()
    }

    private fun scheduleMailboxDelivery() {
        if (!expeditedMailboxPoll.begin()) return
        worker.execute {
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

    private fun broadcast(state: String, detail: String, latencyMs: Long? = null) {
        if (BuildConfig.DEBUG) Log.i("PTT_SESSION_TEST", "$state $detail")
        if (BuildConfig.DEBUG && state == STATE_PLAYED) recordDebugPushWakePlayback()
        val intent =
            Intent(ACTION_STATE)
                .setPackage(packageName)
                .putExtra(EXTRA_STATE, state)
                .putExtra(EXTRA_DETAIL, detail)
        if (latencyMs != null) intent.putExtra(EXTRA_LATENCY_MS, latencyMs)
        sendBroadcast(intent)
    }

    private fun recordDebugPushWakePlayback() {
        val prefs = getSharedPreferences(DEBUG_E2E_PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean(DEBUG_E2E_SERVICE_MARKERS, false)) return
        val countFile = File(filesDir, "ptt-e2e-push-playback-count.txt")
        val count = (countFile.takeIf(File::isFile)?.readText()?.trim()?.toIntOrNull() ?: 0) + 1
        countFile.writeText(count.toString())
        val target = prefs.getInt(DEBUG_E2E_SERVICE_MARKER_TARGET, 1).coerceAtLeast(1)
        File(filesDir, "ptt-e2e-push-playback-state.txt")
            .writeText(if (count >= target) "pass" else "receiving")
    }

    private fun handleServiceFailure(error: Throwable, fallback: String) {
        if (error is ControlApiException && error.status == 401) {
            wipeRevokedDevice()
            return
        }
        broadcast(STATE_ERROR, error.message ?: fallback)
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
        relay?.close()
        relay = null
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
        private const val ACTION_DISARM = "app.ptt.talk.DISARM"
        private const val ACTION_PREPARE = "app.ptt.talk.PREPARE"
        private const val ACTION_BEGIN_TRANSMIT = "app.ptt.talk.BEGIN_TRANSMIT"
        private const val ACTION_END_TRANSMIT = "app.ptt.talk.END_TRANSMIT"
        private const val ACTION_PLAY_HISTORY = "app.ptt.talk.PLAY_HISTORY"
        internal const val ACTION_HARDWARE_BUTTON = "app.ptt.talk.HARDWARE_BUTTON"
        internal const val ACTION_HARDWARE_TOGGLE = "app.ptt.talk.HARDWARE_TOGGLE"
        internal const val ACTION_HARDWARE_SOS = "app.ptt.talk.HARDWARE_SOS"
        private const val ACTION_OVERLAY_ENABLE = "app.ptt.talk.OVERLAY_ENABLE"
        private const val ACTION_OVERLAY_DISABLE = "app.ptt.talk.OVERLAY_DISABLE"
        private const val ACTION_SET_PRESENCE = "app.ptt.talk.SET_PRESENCE"
        const val ACTION_STATE = "app.ptt.talk.SESSION_STATE"
        const val EXTRA_STATE = "state"
        const val EXTRA_DETAIL = "detail"
        internal const val EXTRA_LATENCY_MS = "latencyMs"
        const val STATE_PREPARING = "preparing"
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
        internal const val DEBUG_E2E_PREFS = "physical-e2e-v1"
        internal const val DEBUG_E2E_SYNTHETIC_CAPTURE = "synthetic-capture"
        internal const val DEBUG_E2E_SERVICE_MARKERS = "service-playback-markers"
        internal const val DEBUG_E2E_SERVICE_MARKER_TARGET = "service-playback-marker-target"
        @Volatile private var running = false
        private val HARDWARE_KEY_CODES =
            setOf(
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_BUTTON_1,
                KeyEvent.KEYCODE_F1,
            )

        fun arm(context: Context) {
            context.startForegroundService(Intent(context, PttSessionService::class.java).setAction(ACTION_ARM))
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
