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
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import app.ptt.audio.AndroidAudioEngine
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import app.ptt.media.AuthenticatedUdpRelay
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * User-armed foreground lifetime for control, crypto, floor, and audio work.
 *
 * It deliberately has no boot receiver: after a reboot the user must open the app and tap Stay
 * connected before microphone-capable background operation can resume.
 */
class PttSessionService : Service() {
    private lateinit var audio: AndroidAudioEngine
    private val worker = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "ptt-session-worker") }
    private val scheduler: ScheduledExecutorService =
        Executors.newScheduledThreadPool(2) { runnable -> Thread(runnable, "ptt-session-scheduled") }
    private val secureRandom = SecureRandom()
    @Volatile private var activeChannel: ChannelSummary? = null
    @Volatile private var relayCredential: RelayCredential? = null
    @Volatile private var relay: AuthenticatedUdpRelay? = null
    @Volatile private var outgoing: OutgoingVoiceStream? = null
    @Volatile private var heldFloorToken: String? = null
    private val incoming = mutableMapOf<UUID, IncomingVoiceStream>()
    private val pendingMedia = ArrayDeque<Pair<Long, ByteArray>>()
    private var counterStore: EncryptedSignalProtocolStore? = null
    private var pollingStarted = false

    override fun onCreate() {
        super.onCreate()
        audio = AndroidAudioEngine(this)
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
        when (intent?.action) {
            ACTION_PREPARE -> intent.channel()?.let { channel -> worker.execute { prepareChannel(channel) } }
            ACTION_BEGIN_TRANSMIT -> intent.channel()?.let { channel -> worker.execute { beginTransmit(channel) } }
            ACTION_END_TRANSMIT -> worker.execute { endTransmit() }
            else -> initializeSession()
        }
        setArmed(this, true)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        setArmed(this, false)
        runCatching { endTransmit() }
        relay?.close()
        relay = null
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
        super.onDestroy()
    }

    private fun initializeSession() {
        if (!pollingStarted) {
            pollingStarted = true
            scheduler.execute {
                val session = SecureDeviceStore(this).load() ?: return@execute
                runCatching { PersistentPairwiseCrypto(this, session).ensurePreKeysPublished() }
                    .onFailure { broadcast(STATE_ERROR, it.message ?: "Prekey publication failed") }
            }
            scheduler.scheduleWithFixedDelay(
                { runCatching { pollMailbox() }.onFailure { broadcast(STATE_ERROR, it.message ?: "Mailbox failed") } },
                250,
                250,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    private fun prepareChannel(channel: ChannelSummary) {
        val session = SecureDeviceStore(this).load() ?: return
        broadcast(STATE_PREPARING, "Preparing ${channel.displayName} securely…")
        runCatching {
            outgoing?.close()
            outgoing = null
            heldFloorToken = null
            relay?.close()
            synchronized(incoming) {
                incoming.values.forEach(IncomingVoiceStream::close)
                incoming.clear()
                pendingMedia.clear()
            }
            val credential = ControlApi(session.serverUrl).relayCredential(session, channel.channelId)
            val connected =
                AuthenticatedUdpRelay.connect(
                    credential.relayAddress,
                    credential.ticket,
                    credential.senderDemux,
                    ::onMedia,
                ) { error -> broadcast(STATE_ERROR, error.message ?: "Relay connection failed") }
            activeChannel = channel
            relayCredential = credential
            relay = connected
            broadcast(
                STATE_READY,
                if (channel.role == "listen") "Listening to ${channel.displayName}; your role cannot transmit."
                else "${channel.displayName} is ready. Hold the button to request the floor.",
            )
        }.onFailure { error ->
            activeChannel = null
            relayCredential = null
            relay = null
            broadcast(STATE_ERROR, error.message ?: "Channel preparation failed")
        }
    }

    private fun beginTransmit(channel: ChannelSummary) {
        if (channel.role == "listen") {
            broadcast(STATE_DENIED, "Your channel role cannot transmit.")
            return
        }
        if (activeChannel?.channelId != channel.channelId || relay == null || relayCredential == null) {
            prepareChannel(channel)
        }
        val session = SecureDeviceStore(this).load() ?: return
        val credential = relayCredential ?: return
        val connected = relay ?: return
        if (outgoing != null || heldFloorToken != null) return
        broadcast(STATE_REQUESTING, "Waiting for an authenticated floor grant…")
        runCatching {
            val api = ControlApi(session.serverUrl)
            val grant = api.requestFloor(session, channel, credential)
            if (!grant.granted) {
                broadcast(STATE_DENIED, grant.reason ?: "Channel busy. Try again in a moment.")
                return
            }
            heldFloorToken = grant.requestToken
            val talkId = UUID.randomUUID()
            val key = ByteArray(32).also(secureRandom::nextBytes)
            val announcement =
                MediaEpochAnnouncement(
                    UUID.fromString(channel.channelId),
                    talkId,
                    channel.membershipEpoch,
                    credential.senderDemux,
                    secureRandom.nextLong().toULong(),
                    key,
                    grant.grantedTotMs,
                )
            val crypto = PersistentPairwiseCrypto(this, session)
            val devices = api.channelDevices(session, channel.channelId)
            crypto.announceMediaEpoch(devices, announcement)
            // Give foreground peers one mailbox-poll interval to install the epoch before audio.
            Thread.sleep(300)
            val store = counterStore ?: EncryptedSignalProtocolStore.open(this).also { counterStore = it }
            outgoing =
                OutgoingVoiceStream(
                    audio,
                    connected,
                    credential.demuxToken.base64UrlBytes(),
                    announcement,
                    SqlCipherSFrameCounterStore(store, "${channel.channelId}/${session.deviceId}"),
                ) { error ->
                    broadcast(STATE_ERROR, error.message ?: "Voice transmission failed")
                    worker.execute { endTransmit() }
                }.also(OutgoingVoiceStream::start)
            broadcast(STATE_GRANTED, "Encrypted floor granted for up to ${grant.grantedTotMs / 1000} seconds.")
            scheduler.schedule({ worker.execute { endTransmit() } }, grant.grantedTotMs.toLong(), TimeUnit.MILLISECONDS)
        }.onFailure { error ->
            broadcast(STATE_ERROR, error.message ?: "Could not start transmission")
            endTransmit()
        }
    }

    private fun endTransmit() {
        outgoing?.close()
        outgoing = null
        val token = heldFloorToken
        heldFloorToken = null
        val channel = activeChannel
        val session = SecureDeviceStore(this).load()
        if (token != null && channel != null && session != null) {
            runCatching { ControlApi(session.serverUrl).releaseFloor(session, channel.channelId, token) }
                .onFailure { broadcast(STATE_ERROR, it.message ?: "Floor release failed") }
        }
        if (channel != null) broadcast(STATE_READY, "${channel.displayName} ready.")
    }

    private fun pollMailbox() {
        val channel = activeChannel ?: return
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        val items = api.mailboxItems(session, 25)
        if (items.isEmpty()) return
        val devices = api.channelDevices(session, channel.channelId)
        val crypto = PersistentPairwiseCrypto(this, session)
        val accepted = mutableListOf<String>()
        for (item in items) {
            runCatching { crypto.decryptEnvelope(item.envelope, devices) }
                .onSuccess { opened ->
                    val announcement = opened.announcement
                    if (announcement.channelId.toString() == channel.channelId &&
                        announcement.membershipEpoch == channel.membershipEpoch
                    ) {
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
                                    onEnded = {
                                        worker.execute {
                                            synchronized(incoming) {
                                                incoming.remove(announcement.talkId)?.close()
                                            }
                                        }
                                    },
                                )
                        }
                        accepted += item.itemId
                    }
                }
        }
        if (accepted.isNotEmpty()) {
            api.acknowledgeMailbox(session, accepted)
            replayPendingMedia()
        }
    }

    private fun onMedia(packet: ByteArray) {
        val stream = synchronized(incoming) { incoming.values.firstOrNull { it.matches(packet) } }
        if (stream == null) {
            val now = SystemClock.elapsedRealtime()
            synchronized(incoming) {
                while (pendingMedia.firstOrNull()?.first?.let { now - it > 2_000 } == true) {
                    pendingMedia.removeFirst()
                }
                if (pendingMedia.size >= 100) pendingMedia.removeFirst()
                pendingMedia.addLast(now to packet.copyOf())
            }
            return
        }
        runCatching { stream.accept(packet) }
            .onFailure { broadcast(STATE_ERROR, it.message ?: "Encrypted media was rejected") }
    }

    private fun replayPendingMedia() {
        val packets = synchronized(incoming) {
            buildList {
                while (pendingMedia.isNotEmpty()) add(pendingMedia.removeFirst().second)
            }
        }
        packets.forEach(::onMedia)
    }

    private fun broadcast(state: String, detail: String) {
        if (BuildConfig.DEBUG) Log.i("PTT_SESSION_TEST", "$state $detail")
        sendBroadcast(
            Intent(ACTION_STATE)
                .setPackage(packageName)
                .putExtra(EXTRA_STATE, state)
                .putExtra(EXTRA_DETAIL, detail),
        )
    }

    private fun Intent.channel(): ChannelSummary? {
        val id = getStringExtra(EXTRA_CHANNEL_ID) ?: return null
        return ChannelSummary(
            id,
            getStringExtra(EXTRA_CHANNEL_NAME) ?: return null,
            getStringExtra(EXTRA_CHANNEL_KIND) ?: return null,
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
        const val ACTION_STATE = "app.ptt.talk.SESSION_STATE"
        const val EXTRA_STATE = "state"
        const val EXTRA_DETAIL = "detail"
        const val STATE_PREPARING = "preparing"
        const val STATE_READY = "ready"
        const val STATE_REQUESTING = "requesting"
        const val STATE_GRANTED = "granted"
        const val STATE_DENIED = "denied"
        const val STATE_ERROR = "error"
        private const val EXTRA_CHANNEL_ID = "channelId"
        private const val EXTRA_CHANNEL_NAME = "channelName"
        private const val EXTRA_CHANNEL_KIND = "channelKind"
        private const val EXTRA_MEMBERSHIP_EPOCH = "membershipEpoch"
        private const val EXTRA_RETENTION_DAYS = "retentionDays"
        private const val EXTRA_ROLE = "role"
        private const val PREFS = "ptt-session-lifecycle-v1"
        private const val ARMED = "armed"

        fun arm(context: Context) {
            context.startForegroundService(Intent(context, PttSessionService::class.java).setAction(ACTION_ARM))
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

        fun endTransmit(context: Context) {
            context.startService(Intent(context, PttSessionService::class.java).setAction(ACTION_END_TRANSMIT))
        }

        fun isArmed(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ARMED, false)

        private fun setArmed(context: Context, armed: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ARMED, armed).apply()
        }

        private fun Intent.channel(action: String, value: ChannelSummary): Intent =
            setAction(action)
                .putExtra(EXTRA_CHANNEL_ID, value.channelId)
                .putExtra(EXTRA_CHANNEL_NAME, value.displayName)
                .putExtra(EXTRA_CHANNEL_KIND, value.kind)
                .putExtra(EXTRA_MEMBERSHIP_EPOCH, value.membershipEpoch)
                .putExtra(EXTRA_RETENTION_DAYS, value.retentionDays)
                .putExtra(EXTRA_ROLE, value.role)
    }
}
