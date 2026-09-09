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
import android.util.Log
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
import kotlinx.coroutines.async
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
    private var syntheticAudio = false
    private var diagnosticAudio = false
    private var media: EncryptedCallSession? = null
    private var securityJob: Job? = null
    private var prewarmJob: Job? = null
    private var routeChangeJob: Job? = null
    private val prewarmStateLock = Any()
    private var prewarmAccepting = true
    @Volatile private var prewarmChat: EncryptedChatClient? = null
    @Volatile private var prewarmContext: IncomingPrewarmContext? = null
    @Volatile private var coordinationChat: EncryptedChatClient? = null
    private val finishing = AtomicBoolean(false)
    private var sosPreempting = false
    private var answerRequested = false
    private var telecomAudioActive = false
    private var endpointObjects: List<CallEndpointCompat> = emptyList()
    private var activeEndpointId: String? = null
    private var desiredEndpointId: String? = null

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
                syntheticAudio = BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_SYNTHETIC_AUDIO, false)
                diagnosticAudio = BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_DIAGNOSTIC_AUDIO, false)
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
                activeMediaEpoch = 0
                activeSecuredMediaEpoch = 0
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
                desiredEndpointId = identifier
                routeChangeJob?.cancel()
                routeChangeJob = scope.launch { requestEndpointChangeWithRetry(identifier) }
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
        routeChangeJob?.cancel()
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
                    scope.launch { connectAfterIncomingPrewarm() }
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
                        activeEndpointId = endpoint.identifier.toString()
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
        connectAfterIncomingPrewarm()
    }

    /**
     * Core-Telecom can expose endpoints before an incoming call is fully active. Some OEMs reject
     * a route request in that short window without changing the endpoint flow. Keep Telecom as the
     * sole route owner, but retry the exact user-selected endpoint until its flow acknowledges the
     * change. This also prevents a UI tap from being silently lost on Samsung builds.
     */
    private suspend fun requestEndpointChangeWithRetry(identifier: String) {
        repeat(ROUTE_CHANGE_ATTEMPTS) { attempt ->
            if (!active.get() || desiredEndpointId != identifier) return
            if (activeEndpointId == identifier) return
            val control = callControl
            val endpoint = endpointObjects.firstOrNull { it.identifier.toString() == identifier }
            if (control != null && endpoint != null) {
                try {
                    control.requestEndpointChange(endpoint)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    // Treat platform exceptions like an unacknowledged result and retry below.
                }
            }
            if (activeEndpointId == identifier) return
            if (attempt + 1 < ROUTE_CHANGE_ATTEMPTS) delay(ROUTE_CHANGE_RETRY_MS)
        }
        if (active.get() && desiredEndpointId == identifier && activeEndpointId != identifier) {
            activeStatus = "Could not switch audio route"
        }
    }

    private suspend fun connectAfterIncomingPrewarm() {
        secureAndConnect()
        media?.setTelecomActive(true)
    }

    /**
     * Authenticate the host's current device key and establish the chat-domain PQXDH session
     * while ringing, without claiming a call seat or receiving any call media key. An encrypted
     * call-start event may establish the same ratchet first. Failure remains non-fatal because
     * secureAndConnect retries the authenticated path after answer and still fails closed.
     */
    private suspend fun prewarmIncomingCall(id: String) {
        val session = SecureDeviceStore(this).load() ?: return
        val api = ControlApi(session.serverUrl)
        val chat = EncryptedChatClient(this, session)
        synchronized(prewarmStateLock) {
            if (!prewarmAccepting) return
            prewarmChat = chat
        }
        runCatching { chat.prepareCallCoordination() }
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
                if (hostDevice != null) {
                    if (!chat.hasDataSession(hostDevice)) chat.prepareDataSession(hostDevice)
                    synchronized(prewarmStateLock) {
                        if (!prewarmAccepting) false else {
                            prewarmContext = IncomingPrewarmContext(
                                chat, channel, devices,
                                setOf(CallKeyRecipient(hostDevice.aci.lowercase(), hostDevice.deviceId)),
                            )
                            true
                        }
                    }
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
                        syntheticCapture = syntheticAudio,
                        diagnoseRender = diagnosticAudio,
                    )
                    media = callMedia
                    activeMediaEpoch = credential.callEpoch
                    callMedia.setTelecomActive(telecomAudioActive)
                    // ICE/TURN connection carries no publishable audio while the session remains
                    // muted. Overlap that network setup with Double Ratchet key exchange, then
                    // authorize playback/publication only after every exact-epoch acknowledgement.
                    val transportJob = async {
                        callMedia.prepareTransport(credential.serverUrl, credential.joinToken)
                    }
                    // Reuse the ringing worker's inbox so an authenticated call-key envelope
                    // cannot be drained immediately before answer and then lost with that worker.
                    // Never wait behind a blocking ring-time poll: if the complete authenticated
                    // context is not ready at answer, a fresh client reads the same durable inbox
                    // and SQLCipher ratchet state while the abandoned worker winds down.
                    val prewarm = synchronized(prewarmStateLock) {
                        prewarmAccepting = false
                        val result = prewarmContext
                        prewarmContext = null
                        val abandoned = if (result == null) prewarmChat else null
                        prewarmChat = null
                        Triple(result, abandoned, prewarmJob).also { prewarmJob = null }
                    }
                    prewarm.third?.cancel()
                    prewarm.second?.let { abandoned ->
                        prewarm.third?.invokeOnCompletion { abandoned.closeCallCoordination() }
                    }
                    val prepared = prewarm.first
                    val chat = prepared?.chat ?: EncryptedChatClient(this@CallSessionService, session)
                    coordinationChat = chat
                    // Pay the Keystore/SQLCipher open cost while the invitation is still ringing,
                    // not after another participant answers.
                    chat.prepareCallCoordination()
                    var sentTo = mutableSetOf<CallKeyRecipient>()
                    var acknowledgements = mutableSetOf<String>()
                    var remoteIdentities = mutableMapOf<String, String>()
                    var securingDeadline = System.currentTimeMillis() + RING_TIMEOUT_MS
                    var connected = false
                    var startedTimelineSent = false
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
                        if (cachedChannel == null) {
                            cachedChannel = requireNotNull(api.channels(session).firstOrNull {
                                it.channelId.equals(call.conversationId, true)
                            })
                            cachedDirectory = api.channelDevices(session, requireNotNull(cachedChannel).channelId)
                        }
                        if (!startedTimelineSent && call.requesterIsHost) {
                            // Establish the ordinary authenticated conversation ratchet while the
                            // remote devices are ringing. The invite itself is already visible,
                            // so this work is off the answer-to-audio path and lets the first call
                            // key use an existing Double Ratchet session on both endpoints.
                            startedTimelineSent = true
                            runCatching {
                                sendTimeline(
                                    chat,
                                    call,
                                    requireNotNull(cachedChannel),
                                    CallTimelineEventKind.STARTED,
                                )
                            }
                        }
                        if (call.callEpoch != callMedia.epoch) {
                            callMedia.rotateTo(call.callEpoch)
                            activeMediaEpoch = call.callEpoch
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
                                transportJob.await()
                                callMedia.completeInitialSecurity(peers)
                                activeSecuredMediaEpoch = callMedia.epoch
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
                                activeSecuredMediaEpoch = callMedia.epoch
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
                        activeLocalAudioTracks = callMedia.localAudioTrackCount()
                        activeRemoteAudioTracks = callMedia.remoteAudioTrackCount()
                        activeEncryptionState = callMedia.encryptionStateLabel()
                        activeDiagnosticToneBursts = callMedia.receivedDiagnosticToneBursts()
                        activeDiagnosticPeakRms = callMedia.receivedDiagnosticPeakRms()
                        activeDiagnosticPeakCorrelation = callMedia.receivedDiagnosticPeakCorrelation()
                        activeCaptureDiagnosticToneBursts = callMedia.capturedDiagnosticToneBursts()
                        activeCaptureDiagnosticPeakRms = callMedia.capturedDiagnosticPeakRms()
                        activeCaptureDiagnosticPeakCorrelation =
                            callMedia.capturedDiagnosticPeakCorrelation()
                        activeCaptureDiagnosticFormat = callMedia.captureDiagnosticFormat()
                        activeRenderDiagnosticFormat = callMedia.renderDiagnosticFormat()
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
                if (BuildConfig.DEBUG) {
                    Log.e("PTT_CALL", "Call connection failed at $failureStage", error)
                }
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
        routeChangeJob?.cancel()
        routeChangeJob = null
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
        activeLocalAudioTracks = 0
        activeRemoteAudioTracks = 0
        activeEncryptionState = "NO_FRAME_STATE"
        activeDiagnosticToneBursts = 0
        activeDiagnosticPeakRms = 0f
        activeDiagnosticPeakCorrelation = 0f
        activeCaptureDiagnosticToneBursts = 0
        activeCaptureDiagnosticPeakRms = 0f
        activeCaptureDiagnosticPeakCorrelation = 0f
        activeCaptureDiagnosticFormat = "DISABLED"
        activeRenderDiagnosticFormat = "DISABLED"
        activeSeatClaimedAtMs = 0L
        activeKeySentAtMs = 0L
        activeRemoteKeyInstalledAtMs = 0L
        activeOutboundKeyAckedAtMs = 0L
        activePrewarmReadyAtMs = 0L
        activeKeyReadyAtMs = 0L
        activeMediaConnectedAtMs = 0L
        activeMediaEpoch = 0
        activeSecuredMediaEpoch = 0
        endpointObjects = emptyList()
        activeEndpointId = null
        desiredEndpointId = null
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
        private const val ROUTE_CHANGE_ATTEMPTS = 8
        private const val ROUTE_CHANGE_RETRY_MS = 350L
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
        private const val EXTRA_SYNTHETIC_AUDIO = "syntheticAudio"
        private const val EXTRA_DIAGNOSTIC_AUDIO = "diagnosticAudio"
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
        @Volatile private var activeLocalAudioTracks = 0
        @Volatile private var activeRemoteAudioTracks = 0
        @Volatile private var activeEncryptionState = "NO_FRAME_STATE"
        @Volatile private var activeDiagnosticToneBursts = 0
        @Volatile private var activeDiagnosticPeakRms = 0f
        @Volatile private var activeDiagnosticPeakCorrelation = 0f
        @Volatile private var activeCaptureDiagnosticToneBursts = 0
        @Volatile private var activeCaptureDiagnosticPeakRms = 0f
        @Volatile private var activeCaptureDiagnosticPeakCorrelation = 0f
        @Volatile private var activeCaptureDiagnosticFormat = "DISABLED"
        @Volatile private var activeRenderDiagnosticFormat = "DISABLED"
        @Volatile private var activeSeatClaimedAtMs = 0L
        @Volatile private var activeKeySentAtMs = 0L
        @Volatile private var activeRemoteKeyInstalledAtMs = 0L
        @Volatile private var activeOutboundKeyAckedAtMs = 0L
        @Volatile private var activePrewarmReadyAtMs = 0L
        @Volatile private var activeKeyReadyAtMs = 0L
        @Volatile private var activeMediaConnectedAtMs = 0L
        @Volatile private var activeMediaEpoch = 0
        @Volatile private var activeSecuredMediaEpoch = 0

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
            val localAudioTracks: Int,
            val remoteAudioTracks: Int,
            val encryptionState: String,
            val diagnosticToneBursts: Int,
            val diagnosticPeakRms: Float,
            val diagnosticPeakCorrelation: Float,
            val captureDiagnosticToneBursts: Int,
            val captureDiagnosticPeakRms: Float,
            val captureDiagnosticPeakCorrelation: Float,
            val captureDiagnosticFormat: String,
            val renderDiagnosticFormat: String,
            val seatClaimedAtMs: Long,
            val keySentAtMs: Long,
            val remoteKeyInstalledAtMs: Long,
            val outboundKeyAckedAtMs: Long,
            val prewarmReadyAtMs: Long,
            val keyReadyAtMs: Long,
            val mediaConnectedAtMs: Long,
            val mediaEpoch: Int,
            val securedMediaEpoch: Int,
        )

        fun isActive(): Boolean = active.get()
        fun snapshot(): UiSnapshot = UiSnapshot(
            active.get(), activeCallId, activeIncoming, activeMuted, activeStatus,
            activeRouteName, activeRoutes,
            activeSpeakerAcis, activeConnectionQuality,
            activeLocalAudioTracks, activeRemoteAudioTracks, activeEncryptionState,
            activeDiagnosticToneBursts, activeDiagnosticPeakRms, activeDiagnosticPeakCorrelation,
            activeCaptureDiagnosticToneBursts, activeCaptureDiagnosticPeakRms,
            activeCaptureDiagnosticPeakCorrelation,
            activeCaptureDiagnosticFormat, activeRenderDiagnosticFormat,
            activeSeatClaimedAtMs, activeKeySentAtMs, activeRemoteKeyInstalledAtMs,
            activeOutboundKeyAckedAtMs, activePrewarmReadyAtMs,
            activeKeyReadyAtMs, activeMediaConnectedAtMs,
            activeMediaEpoch, activeSecuredMediaEpoch,
        )

        fun incoming(
            context: Context,
            callId: String,
            syntheticAudio: Boolean = false,
            diagnosticAudio: Boolean = false,
        ) {
            context.startForegroundService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_INCOMING).putExtra(EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_SYNTHETIC_AUDIO, syntheticAudio)
                .putExtra(EXTRA_DIAGNOSTIC_AUDIO, diagnosticAudio))
        }

        fun outgoing(
            context: Context,
            callId: String,
            syntheticAudio: Boolean = false,
            diagnosticAudio: Boolean = false,
        ) {
            context.startForegroundService(Intent(context, CallSessionService::class.java)
                .setAction(ACTION_OUTGOING).putExtra(EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_SYNTHETIC_AUDIO, syntheticAudio)
                .putExtra(EXTRA_DIAGNOSTIC_AUDIO, diagnosticAudio))
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
