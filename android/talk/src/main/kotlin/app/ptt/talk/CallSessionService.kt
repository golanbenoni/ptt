package app.ptt.talk

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.telecom.DisconnectCause
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.collectLatest

/** Core-Telecom owns call endpoints; LiveKit receives only already E2EE-framed media. */
class CallSessionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var callsManager: CallsManager
    private var callControl: CallControlScope? = null
    private var callId: String? = null
    private var incoming = true
    private var media: EncryptedCallSession? = null
    private var securityJob: Job? = null
    private val finishing = AtomicBoolean(false)
    private var sosPreempting = false
    private var endpointObjects: List<CallEndpointCompat> = emptyList()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        callsManager = CallsManager(this)
        callsManager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_INCOMING, ACTION_OUTGOING -> {
                val id = intent.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
                if (runCatching { UUID.fromString(id) }.isFailure || active.getAndSet(true)) return START_NOT_STICKY
                callId = id.lowercase()
                incoming = intent.action == ACTION_INCOMING
                activeCallId = callId
                activeIncoming = incoming
                activeMuted = true
                activeStatus = if (incoming) "Incoming encrypted call" else "Calling securely…"
                PttSessionService.suspendForCall(this)
                startCallForeground(incoming)
                scope.launch { registerCall(id, incoming) }
            }
            ACTION_ANSWER -> scope.launch {
                activeIncoming = false
                activeStatus = "Securing call…"
                callControl?.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
                secureAndConnect()
            }
            ACTION_DECLINE -> scope.launch { finish(DisconnectCause.REJECTED, notifyServer = true) }
            ACTION_END -> scope.launch { finish(DisconnectCause.LOCAL, notifyServer = true) }
            ACTION_MUTE -> scope.launch {
                val muted = intent.getBooleanExtra(EXTRA_MUTED, true)
                activeMuted = muted
                media?.setMuted(muted)
            }
            ACTION_SELECT_ROUTE -> scope.launch {
                val identifier = intent.getStringExtra(EXTRA_ROUTE_ID) ?: return@launch
                endpointObjects.firstOrNull { it.identifier.toString() == identifier }?.let { endpoint ->
                    callControl?.requestEndpointChange(endpoint)
                }
            }
            ACTION_SOS_PREEMPT -> scope.launch {
                sosPreempting = true
                finish(DisconnectCause.LOCAL, notifyServer = true)
            }
            ACTION_REMOTE_END -> scope.launch { finish(DisconnectCause.REMOTE, notifyServer = false) }
            ACTION_ANSWERED_ELSEWHERE -> scope.launch {
                activeStatus = "Answered on your other device"
                finish(DisconnectCause.ANSWERED_ELSEWHERE, notifyServer = false)
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (active.getAndSet(false)) PttSessionService.resumeAfterCall(this)
        securityJob?.cancel()
        media?.releaseNow()
        media = null
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun registerCall(id: String, incoming: Boolean) {
        val attributes = CallAttributesCompat(
            displayName = "PTT Talk",
            address = Uri.parse("ptttalk:encrypted-call"),
            direction = if (incoming) CallAttributesCompat.DIRECTION_INCOMING else CallAttributesCompat.DIRECTION_OUTGOING,
            callType = CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
        )
        try {
            callsManager.addCall(
                attributes,
                onAnswer = {
                    secureAndConnect()
                    media?.setTelecomActive(true)
                },
                onDisconnect = { cause -> finish(cause.code, notifyServer = true) },
                onSetActive = { media?.setTelecomActive(true) },
                onSetInactive = { media?.setTelecomActive(false) },
            ) {
                callControl = this
                launch {
                    currentCallEndpoint.collectLatest { endpoint ->
                        activeRouteName = endpoint.name.toString()
                    }
                }
                launch {
                    availableEndpoints.collectLatest { endpoints ->
                        endpointObjects = endpoints
                        activeRoutes = endpoints.map {
                            AudioRoute(it.identifier.toString(), it.name.toString(), it.type)
                        }
                    }
                }
                launch {
                    isMuted.collectLatest { muted ->
                        activeMuted = muted
                        media?.setMuted(muted)
                    }
                }
                updateNotification(activeCall = !incoming)
                if (!incoming) {
                    scope.launch {
                        setActive()
                        secureAndConnect()
                        media?.setTelecomActive(true)
                    }
                }
            }
        } catch (_: CancellationException) {
        } catch (_: Throwable) {
            finish(DisconnectCause.ERROR, notifyServer = true)
        }
    }

    private fun secureAndConnect() {
        if (securityJob?.isActive == true || media != null) return
        securityJob = scope.launch {
            activeStatus = "Securing call…"
            val session = SecureDeviceStore(this@CallSessionService).load()
                ?: return@launch finish(DisconnectCause.ERROR, notifyServer = false)
            val id = callId ?: return@launch
            try {
                withContext(Dispatchers.IO) {
                    val api = ControlApi(session.serverUrl)
                    val credential = api.answerCall(session, id)
                    require(credential.e2eeRequired)
                    val answeredCall = api.call(session, id)
                    val answeredChannel = api.channels(session).firstOrNull {
                        it.channelId.equals(answeredCall.conversationId, true)
                    }
                    val callMedia = EncryptedCallSession(
                        this@CallSessionService, id, credential.callEpoch, credential.participantIdentity,
                    )
                    media = callMedia
                    val chat = EncryptedChatClient(this@CallSessionService, session)
                    answeredChannel?.let {
                        runCatching { sendTimeline(chat, answeredCall, it, CallTimelineEventKind.ANSWERED) }
                    }
                    var sentTo = mutableSetOf<String>()
                    var acknowledgements = mutableSetOf<String>()
                    var remoteIdentities = mutableMapOf<String, String>()
                    var securingDeadline = System.currentTimeMillis() + RING_TIMEOUT_MS
                    var connected = false
                    var lastRoster: Set<String>? = null
                    while (true) {
                        val call = api.call(session, id)
                        if (call.state == "ended") {
                            api.channels(session).firstOrNull {
                                it.channelId.equals(call.conversationId, true)
                            }?.let { channel ->
                                runCatching {
                                    sendTimeline(
                                        chat, call, channel, CallTimelineEventKind.ENDED,
                                        call.endReason ?: "completed",
                                    )
                                }
                            }
                            throw RemoteCallEnded()
                        }
                        if (call.callEpoch != callMedia.epoch) {
                            callMedia.rotateTo(call.callEpoch)
                            sentTo = mutableSetOf()
                            acknowledgements = mutableSetOf()
                            remoteIdentities = mutableMapOf()
                            securingDeadline = System.currentTimeMillis() + KEY_ROTATION_TIMEOUT_MS
                            activeMuted = true
                            activeStatus = "Securing updated call keys…"
                        }
                        val channels = api.channels(session)
                        val channel = requireNotNull(channels.firstOrNull {
                            it.channelId.equals(call.conversationId, true)
                        })
                        val roster = call.participants.asSequence()
                            .filter { it.state in setOf("invited", "ringing", "connecting", "joined") }
                            .map { it.aci.lowercase() }
                            .toSet()
                        if (lastRoster != null && lastRoster != roster && call.requesterIsHost) {
                            runCatching {
                                sendTimeline(chat, call, channel, CallTimelineEventKind.PARTICIPANTS_CHANGED)
                            }
                        }
                        lastRoster = roster
                        val peers = call.participants.asSequence()
                            .filter { it.state in setOf("connecting", "joined") }
                            .map { it.aci.lowercase() }.filter { it != session.aci.lowercase() }.toSet()
                        val needsKey = peers - sentTo
                        if (needsKey.isNotEmpty()) {
                            chat.sendCallKeyMessage(
                                EncryptedCallKeyMessage(
                                    channelId = UUID.fromString(channel.channelId),
                                    membershipEpoch = channel.membershipEpoch,
                                    callId = UUID.fromString(id), callEpoch = callMedia.epoch,
                                    kind = EncryptedCallKeyMessageKind.ANNOUNCEMENT,
                                    participantIdentity = credential.participantIdentity,
                                    key = callMedia.outboundKey,
                                ), channel, needsKey,
                            )
                            sentTo += needsKey
                        }
                        chat.poll(channels)
                        chat.drainCallKeyMessages().filter {
                            it.callId.toString().equals(id, true) && it.callEpoch == callMedia.epoch &&
                                it.channelId.toString().equals(channel.channelId, true) &&
                                call.participants.any { participant ->
                                    participant.aci.equals(it.senderAci, true) &&
                                        participant.state in setOf("connecting", "joined")
                                }
                        }.forEach { message ->
                            when (message.kind) {
                                EncryptedCallKeyMessageKind.ANNOUNCEMENT -> {
                                    callMedia.installParticipantKey(
                                        requireNotNull(message.key), message.participantIdentity, message.callEpoch,
                                    )
                                    remoteIdentities[message.senderAci.lowercase()] = message.participantIdentity
                                    chat.sendCallKeyMessage(
                                        EncryptedCallKeyMessage(
                                            channelId = message.channelId,
                                            membershipEpoch = message.membershipEpoch,
                                            callId = message.callId, callEpoch = message.callEpoch,
                                            kind = EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT,
                                            participantIdentity = message.participantIdentity,
                                            key = callKeyFingerprint(requireNotNull(message.key)),
                                        ), channel, setOf(message.senderAci.lowercase()),
                                    )
                                }
                                EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT -> if (
                                    message.participantIdentity == credential.participantIdentity &&
                                    MessageDigest.isEqual(message.key, callKeyFingerprint(callMedia.outboundKey))
                                ) {
                                    val sender = message.senderAci.lowercase()
                                    callMedia.acknowledgePeer(sender, message.callEpoch)
                                    acknowledgements += sender
                                }
                            }
                        }
                        if (peers.isNotEmpty() && remoteIdentities.keys.containsAll(peers) &&
                            acknowledgements.containsAll(peers)
                        ) {
                            if (!connected) {
                                callMedia.connect(credential.serverUrl, credential.joinToken, peers)
                                connected = true
                                updateNotification(activeCall = true)
                            } else if (callMedia.state == EncryptedCallMediaState.SECURING) {
                                callMedia.completeRotation(peers)
                            }
                            activeMuted = callMedia.isMuted
                            activeStatus = "Encrypted call active"
                        }
                        if (!connected && System.currentTimeMillis() >= securingDeadline) {
                            error("Timed out securing call")
                        }
                        if (connected && callMedia.state == EncryptedCallMediaState.SECURING &&
                            System.currentTimeMillis() >= securingDeadline
                        ) error("Timed out rotating call keys")
                        val speakerIdentities = callMedia.activeSpeakerIdentities()
                        activeSpeakerAcis = remoteIdentities.filterValues(speakerIdentities::contains).keys
                        if (credential.participantIdentity in speakerIdentities) {
                            activeSpeakerAcis = activeSpeakerAcis + session.aci.lowercase()
                        }
                        activeConnectionQuality = callMedia.connectionQualityLabel()
                        delay(300)
                    }
                }
            } catch (_: RemoteCallEnded) {
                activeStatus = "Call ended"
                finish(DisconnectCause.REMOTE, notifyServer = false)
            } catch (_: Throwable) {
                activeStatus = "Call could not connect"
                finish(DisconnectCause.ERROR, notifyServer = true)
            }
        }
    }

    private class RemoteCallEnded : RuntimeException()

    private suspend fun finish(cause: Int, notifyServer: Boolean) {
        if (!finishing.compareAndSet(false, true)) return
        val session = SecureDeviceStore(this).load()
        val id = callId
        securityJob?.cancel()
        securityJob = null
        runCatching { media?.close() }
        media = null
        if (notifyServer && session != null && id != null) withContext(Dispatchers.IO) {
            runCatching {
                val api = ControlApi(session.serverUrl)
                val call = api.call(session, id)
                val chat = EncryptedChatClient(this@CallSessionService, session)
                api.channels(session).firstOrNull { it.channelId.equals(call.conversationId, true) }?.let { channel ->
                    val kind = if (sosPreempting || call.requesterIsHost) {
                        CallTimelineEventKind.ENDED
                    } else CallTimelineEventKind.PARTICIPANTS_CHANGED
                    val reason = when {
                        sosPreempting -> "sos_preempted"
                        call.requesterIsHost -> "host_ended"
                        else -> ""
                    }
                    runCatching { sendTimeline(chat, call, channel, kind, reason) }
                }
                if (sosPreempting) api.endCall(session, id, "sos_preempted")
                else if (call.requesterIsHost) api.endCall(session, id) else if (cause == DisconnectCause.REJECTED) {
                    api.declineCall(session, id)
                } else api.leaveCall(session, id)
            }
        }
        runCatching { callControl?.disconnect(DisconnectCause(cause)) }
        callControl = null
        active.set(false)
        PttSessionService.resumeAfterCall(this)
        activeCallId = null
        activeStatus = "Call ended"
        activeRouteName = "System audio"
        activeRoutes = emptyList()
        activeSpeakerAcis = emptySet()
        activeConnectionQuality = "Checking"
        endpointObjects = emptyList()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startCallForeground(incoming: Boolean) {
        val notification = notification(incoming, activeCall = !incoming)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else startForeground(NOTIFICATION_ID, notification)
    }

    private fun updateNotification(activeCall: Boolean) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(incoming, activeCall))
    }

    private fun notification(incoming: Boolean, activeCall: Boolean): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, TalkActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val answer = serviceAction(ACTION_ANSWER, 1)
        val decline = serviceAction(if (incoming) ACTION_DECLINE else ACTION_END, 2)
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(if (incoming && !activeCall) "Incoming encrypted call" else "Encrypted call")
            .setContentText(if (activeCall) "End-to-end encrypted audio" else "PTT Talk")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(activeCall)
            .setContentIntent(open)
        if (Build.VERSION.SDK_INT >= 31) {
            val person = Person.Builder().setName("PTT Talk").setImportant(true).build()
            builder.setStyle(
                if (incoming && !activeCall) Notification.CallStyle.forIncomingCall(person, decline, answer)
                else Notification.CallStyle.forOngoingCall(person, decline),
            )
        } else {
            if (incoming && !activeCall) builder.addAction(Notification.Action.Builder(null, "Answer", answer).build())
            builder.addAction(Notification.Action.Builder(null, if (incoming) "Decline" else "End", decline).build())
        }
        return builder.build()
    }

    private fun serviceAction(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
        this, requestCode,
        Intent(this, CallSessionService::class.java).setAction(action).putExtra(EXTRA_CALL_ID, callId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "Encrypted calls", NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = "Incoming and active PTT Talk calls" })
    }

    private fun sendTimeline(
        chat: EncryptedChatClient,
        call: CallSessionSummary,
        channel: ChannelSummary,
        kind: CallTimelineEventKind,
        reason: String = "",
    ) {
        val ended = call.endedAt ?: if (kind == CallTimelineEventKind.ENDED) java.time.Instant.now() else null
        val duration = ended?.toEpochMilli()?.minus((call.activatedAt ?: call.createdAt).toEpochMilli())
            ?.coerceIn(0, 8 * 60 * 60 * 1_000L) ?: 0
        chat.sendCallTimelineEvent(
            EncryptedCallTimelineEvent(
                callId = UUID.fromString(call.callId),
                kind = kind,
                startedAt = call.createdAt,
                durationMs = duration,
                participantCount = call.participants.size.coerceIn(1, 8),
                endReason = if (kind == CallTimelineEventKind.ENDED) reason else "",
            ),
            channel,
        )
    }

    companion object {
        private const val CHANNEL_ID = "ptt-encrypted-calls-v1"
        private const val NOTIFICATION_ID = 4301
        private const val RING_TIMEOUT_MS = 45_000L
        private const val KEY_ROTATION_TIMEOUT_MS = 15_000L
        private const val ACTION_INCOMING = "app.ptt.talk.call.INCOMING"
        private const val ACTION_OUTGOING = "app.ptt.talk.call.OUTGOING"
        private const val ACTION_ANSWER = "app.ptt.talk.call.ANSWER"
        private const val ACTION_DECLINE = "app.ptt.talk.call.DECLINE"
        private const val ACTION_END = "app.ptt.talk.call.END"
        private const val ACTION_MUTE = "app.ptt.talk.call.MUTE"
        private const val ACTION_SELECT_ROUTE = "app.ptt.talk.call.SELECT_ROUTE"
        private const val ACTION_SOS_PREEMPT = "app.ptt.talk.call.SOS_PREEMPT"
        private const val ACTION_REMOTE_END = "app.ptt.talk.call.REMOTE_END"
        private const val ACTION_ANSWERED_ELSEWHERE = "app.ptt.talk.call.ANSWERED_ELSEWHERE"
        private const val EXTRA_CALL_ID = "callId"
        private const val EXTRA_MUTED = "muted"
        private const val EXTRA_ROUTE_ID = "routeId"
        private val active = AtomicBoolean(false)

        private fun callKeyFingerprint(key: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(key).copyOf(16)
        @Volatile private var activeCallId: String? = null
        @Volatile private var activeIncoming = false
        @Volatile private var activeMuted = true
        @Volatile private var activeStatus = ""
        @Volatile private var activeRouteName = "System audio"
        @Volatile private var activeRoutes: List<AudioRoute> = emptyList()
        @Volatile private var activeSpeakerAcis: Set<String> = emptySet()
        @Volatile private var activeConnectionQuality = "Checking"

        data class AudioRoute(val id: String, val name: String, val type: Int)

        data class UiSnapshot(
            val active: Boolean,
            val callId: String?,
            val incoming: Boolean,
            val muted: Boolean,
            val status: String,
            val routeName: String,
            val routes: List<AudioRoute>,
            val activeSpeakerAcis: Set<String>,
            val connectionQuality: String,
        )

        fun isActive(): Boolean = active.get()
        fun snapshot(): UiSnapshot = UiSnapshot(
            active.get(), activeCallId, activeIncoming, activeMuted, activeStatus,
            activeRouteName, activeRoutes,
            activeSpeakerAcis, activeConnectionQuality,
        )

        fun incoming(context: Context, callId: String) {
            context.startForegroundService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_INCOMING).putExtra(EXTRA_CALL_ID, callId))
        }

        fun outgoing(context: Context, callId: String) {
            context.startForegroundService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_OUTGOING).putExtra(EXTRA_CALL_ID, callId))
        }

        fun answer(context: Context) {
            context.startService(Intent(context, CallSessionService::class.java).setAction(ACTION_ANSWER))
        }

        fun end(context: Context) {
            context.startService(Intent(context, CallSessionService::class.java).setAction(ACTION_END))
        }

        fun decline(context: Context) {
            context.startService(Intent(context, CallSessionService::class.java).setAction(ACTION_DECLINE))
        }

        fun setMuted(context: Context, muted: Boolean) {
            activeMuted = muted
            context.startService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_MUTE).putExtra(EXTRA_MUTED, muted))
        }

        fun selectRoute(context: Context, routeId: String) {
            context.startService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_SELECT_ROUTE).putExtra(EXTRA_ROUTE_ID, routeId))
        }

        fun preemptForSos(context: Context) {
            if (active.get()) context.startService(
                Intent(context, CallSessionService::class.java).setAction(ACTION_SOS_PREEMPT),
            )
        }

        fun remoteEnd(context: Context, callId: String) {
            if (activeCallId.equals(callId, true)) context.startService(
                Intent(context, CallSessionService::class.java).setAction(ACTION_REMOTE_END),
            )
        }

        fun answeredElsewhere(context: Context, callId: String) {
            if (activeCallId.equals(callId, true)) context.startService(
                Intent(context, CallSessionService::class.java).setAction(ACTION_ANSWERED_ELSEWHERE),
            )
        }
    }
}
