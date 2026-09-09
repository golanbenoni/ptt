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
    private var prewarmJob: Job? = null
    @Volatile private var prewarmChat: EncryptedChatClient? = null
    @Volatile private var prewarmContext: IncomingPrewarmContext? = null
    @Volatile private var coordinationChat: EncryptedChatClient? = null
    private val finishing = AtomicBoolean(false)
    private var sosPreempting = false
    private var answerRequested = false
    private var telecomAudioActive = false
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
                activeSeatClaimedAtMs = 0L
                activeKeySentAtMs = 0L
                activeRemoteKeyInstalledAtMs = 0L
                activeOutboundKeyAckedAtMs = 0L
                activePrewarmReadyAtMs = 0L
                activeKeyReadyAtMs = 0L
                activeMediaConnectedAtMs = 0L
                activeStatus = if (incoming) "Incoming encrypted call" else "Calling securely…"
                PttSessionService.suspendForCall(this)
                startCallForeground(incoming)
                if (incoming) prewarmJob = scope.launch(Dispatchers.IO) { prewarmIncomingCall(id) }
                scope.launch { registerCall(id, incoming) }
            }
            ACTION_ANSWER -> scope.launch { answerRegisteredCall() }
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
        prewarmJob?.cancel()
        val warmingChat = prewarmChat
        runCatching { coordinationChat?.closeCallCoordination() }
        if (warmingChat !== coordinationChat) runCatching { warmingChat?.closeCallCoordination() }
        coordinationChat = null
        prewarmChat = null
        prewarmContext = null
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
                    answerRequested = false
                    activeIncoming = false
                    telecomAudioActive = true
                    prewarmJob?.cancel()
                    secureAndConnect()
                    media?.setTelecomActive(true)
                },
                onDisconnect = { cause -> finish(cause.code, notifyServer = true) },
                onSetActive = {
                    telecomAudioActive = true
                    media?.setTelecomActive(true)
                },
                onSetInactive = {
                    telecomAudioActive = false
                    media?.setTelecomActive(false)
                },
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
                if (incoming && answerRequested) {
                    scope.launch { answerRegisteredCall() }
                } else if (!incoming) {
                    scope.launch {
                        setActive()
                        telecomAudioActive = true
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

    private suspend fun answerRegisteredCall() {
        activeIncoming = false
        activeStatus = "Securing call…"
        answerRequested = true
        val control = callControl ?: return
        control.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
        answerRequested = false
        telecomAudioActive = true
        media?.setTelecomActive(true)
        prewarmJob?.cancel()
        secureAndConnect()
    }

    /**
     * The encrypted call-start timeline event is delivered during ringing. Decrypting it here
     * establishes the authenticated chat ratchet before the user answers, without claiming a call
     * seat or receiving any call key. Failure is non-fatal because secureAndConnect performs the
     * same authenticated polling after answer and remains fail closed.
     */
    private suspend fun prewarmIncomingCall(id: String) {
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        val chat = EncryptedChatClient(this, session)
        prewarmChat = chat
        val deadline = System.currentTimeMillis() + 10_000L
        while (active.get() && activeCallId.equals(id, true) && System.currentTimeMillis() < deadline) {
            val prepared = runCatching {
                val call = api.call(session, id)
                if (call.state == "ended") return
                val channels = api.channels(session)
                val channel = channels.firstOrNull { it.channelId.equals(call.conversationId, true) }
                    ?: return@runCatching false
                val devices = api.channelDevices(session, channel.channelId)
                chat.pollCallCoordination(channel, devices)
                val hostParticipant = call.participants.firstOrNull {
                    it.aci.equals(call.hostAci, true) &&
                        it.state in setOf("connecting", "joined") && it.claimedDeviceId != null
                }
                val hostDevice = hostParticipant?.let { participant ->
                    devices.firstOrNull {
                        it.aci.equals(participant.aci, true) && it.deviceId == participant.claimedDeviceId
                    }
                }
                if (hostDevice != null && chat.hasDataSession(hostDevice)) {
                    prewarmContext = IncomingPrewarmContext(
                        chat, channel, devices,
                        setOf(CallKeyRecipient(hostDevice.aci.lowercase(), hostDevice.deviceId)),
                    )
                    true
                } else false
            }.getOrDefault(false)
            if (prepared) {
                activePrewarmReadyAtMs = System.currentTimeMillis()
                return
            }
            delay(100)
        }
    }

    private fun secureAndConnect() {
        if (securityJob?.isActive == true || media != null) return
        securityJob = scope.launch {
            activeStatus = "Securing call…"
            var failureStage = "loading-device-state"
            val session = SecureDeviceStore(this@CallSessionService).load()
                ?: return@launch finish(DisconnectCause.ERROR, notifyServer = false)
            val id = callId ?: return@launch
            try {
                withContext(Dispatchers.IO) {
                    val api = ControlApi(session.serverUrl)
                    failureStage = "claiming-account-seat"
                    val credential = api.answerCall(session, id)
                    activeSeatClaimedAtMs = System.currentTimeMillis()
                    require(credential.e2eeRequired)
                    failureStage = "creating-encrypted-media"
                    val callMedia = EncryptedCallSession(
                        this@CallSessionService, id, credential.callEpoch, credential.participantIdentity,
                    )
                    media = callMedia
                    callMedia.setTelecomActive(telecomAudioActive)
                    // Reuse the ringing worker's inbox so an authenticated call-key envelope
                    // cannot be drained immediately before answer and then lost with that worker.
                    val prepared = prewarmContext
                    prewarmContext = null
                    val chat = prepared?.chat ?: prewarmChat ?:
                        EncryptedChatClient(this@CallSessionService, session)
                    coordinationChat = chat
                    prewarmChat = null
                    var sentTo = mutableSetOf<CallKeyRecipient>()
                    var acknowledgements = mutableSetOf<String>()
                    var remoteIdentities = mutableMapOf<String, String>()
                    var securingDeadline = System.currentTimeMillis() + RING_TIMEOUT_MS
                    var connected = false
                    var answeredTimelineSent = false
                    var lastRoster: Set<String>? = null
                    var cachedChannel: ChannelSummary? = prepared?.channel
                    var cachedDirectory = prepared?.devices.orEmpty()
                    var cachedDirectoryPeers = prepared?.peerDevices.orEmpty()
                    var cachedCall: CallSessionSummary? = null
                    var reuseRosterOnce = false
                    val processedCallKeyMessages = mutableSetOf<UUID>()
                    while (true) {
                        val call = if (reuseRosterOnce) {
                            reuseRosterOnce = false
                            requireNotNull(cachedCall)
                        } else {
                            api.call(session, id).also { cachedCall = it }
                        }
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
                        val localParticipant = call.participants.firstOrNull {
                            it.aci.equals(session.aci, true)
                        }
                        if (localParticipant?.claimedDeviceId != session.deviceId ||
                            localParticipant.state !in setOf("connecting", "joined")
                        ) {
                            activeStatus = if (localParticipant?.claimedDeviceId != session.deviceId) {
                                "Answered on your other device"
                            } else {
                                "You are no longer in this call"
                            }
                            throw RemoteCallEnded()
                        }
                        if (call.callEpoch != callMedia.epoch) {
                            callMedia.rotateTo(call.callEpoch)
                            sentTo = mutableSetOf()
                            acknowledgements = mutableSetOf()
                            remoteIdentities = mutableMapOf()
                            cachedChannel = null
                            cachedDirectory = emptyList()
                            cachedDirectoryPeers = emptySet()
                            securingDeadline = System.currentTimeMillis() + KEY_ROTATION_TIMEOUT_MS
                            activeMuted = true
                            activeStatus = "Securing updated call keys…"
                        }
                        val peerDevices = call.participants.asSequence()
                            .filter { it.state in setOf("connecting", "joined") }
                            .filter { !it.aci.equals(session.aci, true) }
                            .map { participant ->
                                CallKeyRecipient(
                                    participant.aci.lowercase(),
                                    requireNotNull(participant.claimedDeviceId) {
                                        "An active call participant must have a claimed device"
                                    },
                                )
                            }.toSet()
                        if (peerDevices.isEmpty()) {
                            if (System.currentTimeMillis() >= securingDeadline) {
                                error("Timed out waiting for another participant")
                            }
                            activeStatus = "Waiting for others to answer…"
                            // Do not poll or decrypt the general chat queue while nobody else has
                            // claimed a seat. A tight, cheap roster poll notices an answer quickly.
                            delay(75)
                            continue
                        }
                        if (cachedChannel == null || cachedDirectoryPeers != peerDevices) {
                            val refreshedChannel = requireNotNull(api.channels(session).firstOrNull {
                                it.channelId.equals(call.conversationId, true)
                            })
                            cachedChannel = refreshedChannel
                            cachedDirectory = api.channelDevices(session, refreshedChannel.channelId)
                            cachedDirectoryPeers = peerDevices
                        }
                        val channel = requireNotNull(cachedChannel)
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
                        val peers = peerDevices.mapTo(mutableSetOf()) { it.aci }
                        val readyToSend = peerDevices - sentTo
                        val readyDirectoryDevices = readyToSend.mapNotNull { recipient ->
                            cachedDirectory.firstOrNull { recipient.matches(it) }
                        }
                        if (readyToSend.isNotEmpty() &&
                            readyDirectoryDevices.size == readyToSend.size &&
                            readyDirectoryDevices.all(chat::hasDataSession)
                        ) {
                            // Ring-time prewarming (or a previously authenticated conversation)
                            // already established every required ratchet. Publish our media key
                            // immediately instead of paying for an empty mailbox round trip first.
                            failureStage = "sending-call-keys"
                            chat.sendCallKeyMessage(
                                EncryptedCallKeyMessage(
                                    channelId = UUID.fromString(channel.channelId),
                                    membershipEpoch = channel.membershipEpoch,
                                    callId = UUID.fromString(id), callEpoch = callMedia.epoch,
                                    kind = EncryptedCallKeyMessageKind.ANNOUNCEMENT,
                                    participantIdentity = credential.participantIdentity,
                                    key = callMedia.outboundKey,
                                ), channel, readyToSend, cachedDirectory,
                            )
                            if (activeKeySentAtMs == 0L) activeKeySentAtMs = System.currentTimeMillis()
                            sentTo += readyToSend
                        }
                        // Consume a timeline/prewarm envelope before creating an outbound
                        // first-contact prekey message. This avoids simultaneous PQXDH session
                        // initiation when both sides answer at nearly the same instant. If every
                        // ratchet was already authenticated above, this pass can receive the peer's
                        // announcement without delaying our own.
                        failureStage = "receiving-call-keys"
                        chat.pollCallCoordination(channel, cachedDirectory)
                        var sentAcknowledgement = false
                        chat.pendingCallKeyMessages().forEach { message ->
                            if (message.messageId in processedCallKeyMessages) return@forEach
                            val isCurrentAuthorizedMessage =
                                message.callId.toString().equals(id, true) &&
                                    message.callEpoch == callMedia.epoch &&
                                    message.channelId.toString().equals(channel.channelId, true) &&
                                    call.participants.any { participant ->
                                        participant.aci.equals(message.senderAci, true) &&
                                            participant.claimedDeviceId == message.senderDeviceId &&
                                            participant.state in setOf("connecting", "joined")
                                    }
                            if (!isCurrentAuthorizedMessage) {
                                processedCallKeyMessages += message.messageId
                                return@forEach
                            }
                            when (message.kind) {
                                EncryptedCallKeyMessageKind.ANNOUNCEMENT -> {
                                    callMedia.installParticipantKey(
                                        requireNotNull(message.key), message.participantIdentity, message.callEpoch,
                                    )
                                    if (activeRemoteKeyInstalledAtMs == 0L) {
                                        activeRemoteKeyInstalledAtMs = System.currentTimeMillis()
                                    }
                                    remoteIdentities[message.senderAci.lowercase()] = message.participantIdentity
                                    chat.sendCallKeyMessage(
                                        EncryptedCallKeyMessage(
                                            channelId = message.channelId,
                                            membershipEpoch = message.membershipEpoch,
                                            callId = message.callId, callEpoch = message.callEpoch,
                                            kind = EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT,
                                            participantIdentity = message.participantIdentity,
                                            key = callKeyFingerprint(requireNotNull(message.key)),
                                        ), channel, setOf(
                                            CallKeyRecipient(message.senderAci.lowercase(), message.senderDeviceId),
                                        ), cachedDirectory,
                                    )
                                    sentAcknowledgement = true
                                }
                                EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT -> if (
                                    message.participantIdentity == credential.participantIdentity &&
                                    MessageDigest.isEqual(message.key, callKeyFingerprint(callMedia.outboundKey))
                                ) {
                                    val sender = message.senderAci.lowercase()
                                    callMedia.acknowledgePeer(sender, message.callEpoch)
                                    acknowledgements += sender
                                    if (activeOutboundKeyAckedAtMs == 0L) {
                                        activeOutboundKeyAckedAtMs = System.currentTimeMillis()
                                    }
                                }
                            }
                            processedCallKeyMessages += message.messageId
                        }
                        val needsKey = peerDevices - sentTo
                        if (needsKey.isNotEmpty()) {
                            failureStage = "sending-call-keys"
                            chat.sendCallKeyMessage(
                                EncryptedCallKeyMessage(
                                    channelId = UUID.fromString(channel.channelId),
                                    membershipEpoch = channel.membershipEpoch,
                                    callId = UUID.fromString(id), callEpoch = callMedia.epoch,
                                    kind = EncryptedCallKeyMessageKind.ANNOUNCEMENT,
                                    participantIdentity = credential.participantIdentity,
                                    key = callMedia.outboundKey,
                                ), channel, needsKey, cachedDirectory,
                            )
                            if (activeKeySentAtMs == 0L) activeKeySentAtMs = System.currentTimeMillis()
                            sentTo += needsKey
                        }
                        // A single immediate mailbox pass is safe against the just-authenticated
                        // roster and removes an unnecessary control-plane round trip between an
                        // announcement and its acknowledgement. The next pass always refreshes
                        // authoritative call state before accepting further coordination.
                        if (!connected && (sentAcknowledgement || needsKey.isNotEmpty())) {
                            reuseRosterOnce = true
                        }
                        if (peers.isNotEmpty() && remoteIdentities.keys.containsAll(peers) &&
                            acknowledgements.containsAll(peers)
                        ) {
                            if (!connected) {
                                failureStage = "connecting-encrypted-media"
                                activeStatus = "Connecting encrypted audio…"
                                activeKeyReadyAtMs = System.currentTimeMillis()
                                callMedia.connect(credential.serverUrl, credential.joinToken, peers)
                                activeMediaConnectedAtMs = System.currentTimeMillis()
                                connected = true
                                // Removal is deferred until protected media is established. A
                                // crash before here replays the durable envelopes; local IDs avoid
                                // reprocessing them in the same attempt.
                                chat.removeCallKeyMessages(processedCallKeyMessages)
                                processedCallKeyMessages.clear()
                                updateNotification(activeCall = true)
                            } else if (callMedia.state == EncryptedCallMediaState.SECURING) {
                                callMedia.completeRotation(peers)
                            }
                            activeMuted = callMedia.isMuted
                            activeStatus = "Encrypted call active"
                            failureStage = "maintaining-call"
                            if (!answeredTimelineSent) {
                                answeredTimelineSent = true
                                runCatching { sendTimeline(chat, call, channel, CallTimelineEventKind.ANSWERED) }
                            }
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
                        // Once another account has claimed a seat, key announcements and
                        // acknowledgements are on the user-visible answer path. Poll briefly at a
                        // low latency until protected media is ready, then return to the ordinary
                        // coordination cadence.
                        val securingWithPeer = peers.isNotEmpty() &&
                            (!connected || callMedia.state == EncryptedCallMediaState.SECURING)
                        delay(if (securingWithPeer) 75 else 300)
                    }
                }
            } catch (_: RemoteCallEnded) {
                activeStatus = "Call ended"
                finish(DisconnectCause.REMOTE, notifyServer = false)
            } catch (error: Throwable) {
                val mediaStage = error.message?.takeIf { it.startsWith("call-media-") }
                val safeFailure = when (error) {
                    is ControlApiException -> "${mediaStage ?: failureStage}:${error.code}"
                    is CallKeyDeliveryException -> "${failureStage}:${error.stage}"
                    else -> "${mediaStage ?: failureStage}:${error.javaClass.simpleName}"
                }
                activeStatus = if (BuildConfig.DEBUG) {
                    "Call could not connect ($safeFailure)"
                } else "Call could not connect"
                finish(DisconnectCause.ERROR, notifyServer = true)
            }
        }
    }

    private data class IncomingPrewarmContext(
        val chat: EncryptedChatClient,
        val channel: ChannelSummary,
        val devices: List<ChannelDevice>,
        val peerDevices: Set<CallKeyRecipient>,
    )

    private class RemoteCallEnded : RuntimeException()

    private suspend fun finish(cause: Int, notifyServer: Boolean) {
        if (!finishing.compareAndSet(false, true)) return
        val session = SecureDeviceStore(this).load()
        val id = callId
        securityJob?.cancel()
        securityJob = null
        prewarmJob?.cancel()
        prewarmJob = null
        val warmingChat = prewarmChat
        prewarmChat = null
        prewarmContext = null
        runCatching { coordinationChat?.closeCallCoordination() }
        if (warmingChat !== coordinationChat) runCatching { warmingChat?.closeCallCoordination() }
        coordinationChat = null
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
        answerRequested = false
        telecomAudioActive = false
        active.set(false)
        PttSessionService.resumeAfterCall(this)
        activeCallId = null
        activeStatus = "Call ended"
        activeRouteName = "System audio"
        activeRoutes = emptyList()
        activeSpeakerAcis = emptySet()
        activeConnectionQuality = "Checking"
        activeSeatClaimedAtMs = 0L
        activeKeySentAtMs = 0L
        activeRemoteKeyInstalledAtMs = 0L
        activeOutboundKeyAckedAtMs = 0L
        activePrewarmReadyAtMs = 0L
        activeKeyReadyAtMs = 0L
        activeMediaConnectedAtMs = 0L
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
        @Volatile private var activeSeatClaimedAtMs = 0L
        @Volatile private var activeKeySentAtMs = 0L
        @Volatile private var activeRemoteKeyInstalledAtMs = 0L
        @Volatile private var activeOutboundKeyAckedAtMs = 0L
        @Volatile private var activePrewarmReadyAtMs = 0L
        @Volatile private var activeKeyReadyAtMs = 0L
        @Volatile private var activeMediaConnectedAtMs = 0L

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
            val seatClaimedAtMs: Long,
            val keySentAtMs: Long,
            val remoteKeyInstalledAtMs: Long,
            val outboundKeyAckedAtMs: Long,
            val prewarmReadyAtMs: Long,
            val keyReadyAtMs: Long,
            val mediaConnectedAtMs: Long,
        )

        fun isActive(): Boolean = active.get()
        fun snapshot(): UiSnapshot = UiSnapshot(
            active.get(), activeCallId, activeIncoming, activeMuted, activeStatus,
            activeRouteName, activeRoutes,
            activeSpeakerAcis, activeConnectionQuality,
            activeSeatClaimedAtMs, activeKeySentAtMs, activeRemoteKeyInstalledAtMs,
            activeOutboundKeyAckedAtMs, activePrewarmReadyAtMs,
            activeKeyReadyAtMs, activeMediaConnectedAtMs,
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
