package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowInsets
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.security.MessageDigest
import kotlin.concurrent.thread
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.util.KeyHelper

/** Production application shell. The legacy encrypted-tone fixture lives in tools/net. */
class TalkActivity : Activity() {
    private lateinit var credentials: SecureDeviceStore
    private var session: DeviceSession? = null
    private var incomingAction: String? = null
    private var incomingToken: String? = null
    private var configuredServer: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val tones = ToneFeedback()
    private var recoveryScreen = 0
    private var selectedChannel: ChannelSummary? = null
    private var talkPressed = false
    private var armButton: Button? = null
    private var talkButton: Button? = null
    private var talkStatusView: TextView? = null
    private var presenceStatusView: TextView? = null
    private var sosButton: Button? = null
    private var sosActive = false
    private var receiverRegistered = false
    private val sessionStateReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != PttSessionService.ACTION_STATE) return
                val state = intent.getStringExtra(PttSessionService.EXTRA_STATE) ?: return
                val detail = intent.getStringExtra(PttSessionService.EXTRA_DETAIL).orEmpty()
                if (state == PttSessionService.STATE_PRESENCE) {
                    presenceStatusView?.text = detail
                    return
                }
                talkStatusView?.text = detail
                when (state) {
                    PttSessionService.STATE_PREPARING, PttSessionService.STATE_REQUESTING -> {
                        talkButton?.isEnabled = false
                        talkButton?.text = if (state == PttSessionService.STATE_REQUESTING) "Requesting floor…" else "Hold to talk"
                    }
                    PttSessionService.STATE_READY -> {
                        talkPressed = false
                        talkButton?.text = "Hold to talk"
                        talkButton?.isEnabled = selectedChannel?.role != "listen" && PttSessionService.isArmed(this@TalkActivity)
                        talkStatusView?.setTextColor(Color.rgb(8, 117, 92))
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_GRANTED -> {
                        talkButton?.isEnabled = true
                        talkButton?.text = "Floor granted — talking"
                        talkStatusView?.setTextColor(Color.rgb(8, 117, 92))
                        if (!detail.startsWith("Silent SOS")) tones.granted()
                    }
                    PttSessionService.STATE_DENIED -> {
                        talkPressed = false
                        talkButton?.isEnabled = true
                        talkButton?.text = "Hold to talk"
                        talkStatusView?.setTextColor(Color.rgb(150, 40, 40))
                        tones.denied()
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_ERROR -> {
                        talkPressed = false
                        talkButton?.isEnabled = selectedChannel != null && PttSessionService.isArmed(this@TalkActivity)
                        talkButton?.text = "Hold to talk"
                        talkStatusView?.setTextColor(Color.rgb(150, 40, 40))
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_REVOKED -> {
                        session = null
                        selectedChannel = null
                        talkPressed = false
                        recoveryScreen++
                        showOnboarding()
                    }
                    PttSessionService.STATE_RECEIVING, PttSessionService.STATE_HISTORY_UPDATED -> {
                        val emergency = detail.startsWith("SOS ")
                        talkStatusView?.setTextColor(if (emergency) Color.rgb(180, 20, 35) else Color.rgb(8, 117, 92))
                        if (emergency) tones.emergency()
                    }
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        credentials = SecureDeviceStore(this)
        configuredServer = intent.getStringExtra("ptt_server") ?: credentials.loadServer()
        acceptDeepLink(intent)
        session = credentials.load()
        when {
            session != null -> showTalkHome(requireNotNull(session))
            credentials.loadPendingLink() != null -> showPendingDeviceLink(requireNotNull(credentials.loadPendingLink()))
            credentials.loadPending() != null -> showPendingRecovery(requireNotNull(credentials.loadPending()))
            incomingAction == "recover" -> showRecovery()
            else -> showOnboarding()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptDeepLink(intent)
        if (session == null) {
            if (incomingAction == "recover") showRecovery() else showOnboarding()
        }
    }

    override fun onStart() {
        super.onStart()
        if (!receiverRegistered) {
            val filter = IntentFilter(PttSessionService.ACTION_STATE)
            registerReceiver(sessionStateReceiver, filter, RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }
    }

    override fun onStop() {
        if (receiverRegistered) {
            unregisterReceiver(sessionStateReceiver)
            receiverRegistered = false
        }
        super.onStop()
    }

    override fun onDestroy() {
        tones.close()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_ARM_PERMISSIONS) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            PttSessionService.arm(this)
            armButton?.text = "Disconnect background session"
            selectedChannel?.let { PttSessionService.prepare(this, it) }
        } else {
            armButton?.text = "Stay connected"
        }
    }

    private fun acceptDeepLink(intent: Intent) {
        val data = intent.data ?: return
        if (data.scheme != "ptttalk" || data.host !in setOf("enroll", "recover")) return
        incomingAction = data.host
        incomingToken = data.getQueryParameter("token")?.takeIf { it.length in 32..256 }
        data.getQueryParameter("server")?.let { candidate ->
            runCatching { ControlApi(candidate) }.onSuccess { configuredServer = candidate.trimEnd('/') }
        }
    }

    private fun showOnboarding() {
        val content = column()
        content.addView(title("PTT Talk"))
        content.addView(body("Join your private team with the invitation and email sent by your administrator."))
        val server = field("Server URL", defaultServer())
        val email = field("Email address")
        val invitation = field("Invitation code", secret = true)
        val token = field("Magic-link token", incomingToken.orEmpty(), secret = true)
        val deviceName = field("Device name", defaultDeviceName())
        content.addView(server)
        content.addView(email)
        content.addView(invitation)
        val requestLink = action("Email my secure sign-in link")
        content.addView(requestLink)
        content.addView(token)
        content.addView(deviceName)
        val complete = action("Finish enrollment")
        content.addView(complete)
        val status = body(if (incomingAction == "recover") "This recovery link requires administrator approval." else "")
        content.addView(status)
        content.addView(action("Link as a second device").apply { setOnClickListener { showDeviceLinkClaim() } })
        content.addView(action("Recover an existing account").apply { setOnClickListener { showRecovery() } })

        requestLink.setOnClickListener {
            runAction(requestLink, status) {
                require(email.text.toString().contains('@')) { "Enter your email address." }
                require(invitation.text.isNotBlank()) { "Enter the invitation code." }
                configuredServer = server.text.toString().trimEnd('/')
                ControlApi(server.text.toString()).requestMagicLink(
                    email.text.toString().trim(),
                    invitation.text.toString().trim(),
                )
                "Link requested. Open the email on this device, then return here."
            }
        }
        complete.setOnClickListener {
            runAction(complete, status) {
                require(incomingAction != "recover") { "Recovery approval is not available from this enrollment form." }
                val magicToken = token.text.toString().trim()
                require(magicToken.isNotBlank()) { "Open the email link or paste its token." }
                require(deviceName.text.isNotBlank()) { "Name this device." }
                configuredServer = server.text.toString().trimEnd('/')
                val identity = localIdentity()
                val enrolled =
                    ControlApi(server.text.toString()).consumeMagicLink(
                        magicToken,
                        deviceName.text.toString().trim(),
                        identity.publicKey.serialize(),
                    )
                credentials.save(enrolled)
                session = enrolled
                incomingToken = null
                runOnUiThread { showTalkHome(enrolled) }
                "Enrollment complete."
            }
        }
        setContentView(scroll(content))
    }

    private fun showDeviceLinkClaim() {
        recoveryScreen++
        val content = column()
        content.addView(title("Link this device"))
        content.addView(body("On an active device, choose Link another device. Enter its request ID and one-time code here."))
        val server = field("Server URL", defaultServer())
        val requestId = field("Link request ID")
        val linkCode = field("One-time link code", secret = true)
        val deviceName = field("Device name", defaultDeviceName())
        content.addView(server)
        content.addView(requestId)
        content.addView(linkCode)
        content.addView(deviceName)
        val claim = action("Send approval request")
        val status = body("")
        content.addView(claim)
        content.addView(status)
        content.addView(action("Back to enrollment").apply { setOnClickListener { showOnboarding() } })
        claim.setOnClickListener {
            runAction(claim, status) {
                require(requestId.text.isNotBlank()) { "Enter the request ID from the active device." }
                require(linkCode.text.isNotBlank()) { "Enter the one-time link code." }
                require(deviceName.text.isNotBlank()) { "Name this device." }
                configuredServer = server.text.toString().trimEnd('/')
                EncryptedSignalProtocolStore.resetLocalDeviceState(this)
                val identity = IdentityKeyPair.generate()
                EncryptedSignalProtocolStore.open(
                    this,
                    identity,
                    KeyHelper.generateRegistrationId(false),
                ).close()
                val pending =
                    ControlApi(server.text.toString()).claimDeviceLink(
                        requestId.text.toString().trim(),
                        linkCode.text.toString().trim(),
                        deviceName.text.toString().trim(),
                        identity.publicKey.serialize(),
                    )
                credentials.savePendingLink(pending)
                runOnUiThread { showPendingDeviceLink(pending) }
                "Approval requested."
            }
        }
        setContentView(scroll(content))
    }

    private fun showPendingDeviceLink(pending: PendingDeviceLink) {
        val screen = ++recoveryScreen
        val content = column()
        content.addView(title("Device approval pending"))
        content.addView(body("Return to the active device and approve request ${pending.requestId.take(8)}…."))
        val status = body("Waiting for the active device…")
        val progress = ProgressBar(this)
        val refresh = action("Check now")
        content.addView(status)
        content.addView(progress)
        content.addView(refresh)
        content.addView(action("Cancel on this device").apply {
            setOnClickListener {
                recoveryScreen++
                credentials.clear()
                EncryptedSignalProtocolStore.resetLocalDeviceState(this@TalkActivity)
                showOnboarding()
            }
        })
        setContentView(scroll(content))

        fun check() {
            refresh.isEnabled = false
            thread(name = "ptt-device-link-status") {
                val result = runCatching { ControlApi(pending.serverUrl).deviceLinkStatus(pending) }
                runOnUiThread {
                    if (screen != recoveryScreen || isFinishing || isDestroyed) return@runOnUiThread
                    refresh.isEnabled = true
                    result.fold(
                        onSuccess = { response ->
                            if (response.status == "active") {
                                val active =
                                    DeviceSession(
                                        pending.serverUrl,
                                        response.aci,
                                        response.deviceId,
                                        response.mailboxId,
                                        pending.claimToken,
                                    )
                                credentials.save(active)
                                session = active
                                showTalkHome(active)
                            } else {
                                status.text = "Waiting for the active device…"
                                mainHandler.postDelayed({ if (screen == recoveryScreen) check() }, 5_000)
                            }
                        },
                        onFailure = {
                            status.text = safeMessage(it)
                            mainHandler.postDelayed({ if (screen == recoveryScreen) check() }, 10_000)
                        },
                    )
                }
            }
        }
        refresh.setOnClickListener { check() }
        check()
    }

    private fun showRecovery() {
        recoveryScreen++
        val content = column()
        content.addView(title("Recover PTT Talk"))
        content.addView(
            body(
                "Recovery needs a fresh email link and approval from a different instance administrator. " +
                    "Approval revokes this account's old devices and rotates its channel keys.",
            ),
        )
        val server = field("Server URL", defaultServer())
        val email = field("Account email")
        val token = field("Recovery-link token", incomingToken.orEmpty(), secret = true)
        val deviceName = field("Device name", defaultDeviceName())
        content.addView(server)
        content.addView(email)
        val request = action("Email a recovery link")
        content.addView(request)
        content.addView(token)
        content.addView(deviceName)
        val submit = action("Request administrator approval")
        content.addView(submit)
        val status = body("")
        content.addView(status)
        content.addView(action("Back to enrollment").apply { setOnClickListener { showOnboarding() } })

        request.setOnClickListener {
            runAction(request, status) {
                require(email.text.toString().contains('@')) { "Enter your account email address." }
                configuredServer = server.text.toString().trimEnd('/')
                ControlApi(server.text.toString()).requestRecovery(email.text.toString().trim())
                "If that account exists, its recovery email is on the way."
            }
        }
        submit.setOnClickListener {
            runAction(submit, status) {
                val recoveryToken = token.text.toString().trim()
                require(recoveryToken.isNotBlank()) { "Open the recovery email link or paste its token." }
                require(deviceName.text.isNotBlank()) { "Name this device." }
                configuredServer = server.text.toString().trimEnd('/')

                // Recovery is the one flow allowed to replace local cryptographic identity. It is
                // explicit here and paired with server-side revocation of every former device.
                EncryptedSignalProtocolStore.resetForAccountRecovery(this)
                val identity = IdentityKeyPair.generate()
                val registrationId = KeyHelper.generateRegistrationId(false)
                EncryptedSignalProtocolStore.open(this, identity, registrationId).close()
                val api = ControlApi(server.text.toString())
                val claim =
                    api.consumeRecovery(
                        recoveryToken,
                        deviceName.text.toString().trim(),
                        identity.publicKey.serialize(),
                    )
                val pending = PendingRecovery(server.text.toString().trimEnd('/'), claim.requestId, claim.claimToken)
                credentials.savePending(pending)
                incomingToken = null
                incomingAction = null
                runOnUiThread { showPendingRecovery(pending) }
                "Approval requested."
            }
        }
        setContentView(scroll(content))
    }

    private fun showPendingRecovery(pending: PendingRecovery) {
        val screen = ++recoveryScreen
        val content = column()
        content.addView(title("Recovery pending"))
        content.addView(body("A different instance administrator must approve this request. This screen checks automatically."))
        val status = body("Waiting for administrator approval…")
        content.addView(status)
        val progress = ProgressBar(this)
        content.addView(progress)
        val refresh = action("Check now")
        content.addView(refresh)
        content.addView(action("Cancel on this device").apply {
            setOnClickListener {
                recoveryScreen++
                credentials.clear()
                showRecovery()
            }
        })
        setContentView(scroll(content))

        fun check() {
            refresh.isEnabled = false
            thread(name = "ptt-recovery-status") {
                val result = runCatching { ControlApi(pending.serverUrl).recoveryStatus(pending) }
                runOnUiThread {
                    if (screen != recoveryScreen || isFinishing || isDestroyed) return@runOnUiThread
                    refresh.isEnabled = true
                    result.fold(
                        onSuccess = { response ->
                            when (response.status) {
                                "approved" -> {
                                    val active =
                                        DeviceSession(
                                            serverUrl = pending.serverUrl,
                                            aci = requireNotNull(response.aci),
                                            deviceId = requireNotNull(response.deviceId),
                                            mailboxId = requireNotNull(response.mailboxId),
                                            accessToken = pending.claimToken,
                                        )
                                    credentials.save(active)
                                    session = active
                                    showTalkHome(active)
                                }
                                "pending_admin" -> {
                                    status.text = "Waiting for administrator approval…"
                                    mainHandler.postDelayed({ if (screen == recoveryScreen) check() }, 10_000)
                                }
                                "denied" -> {
                                    progress.visibility = android.view.View.GONE
                                    status.setTextColor(Color.rgb(150, 40, 40))
                                    status.text = "The administrator denied this recovery request."
                                }
                                else -> {
                                    progress.visibility = android.view.View.GONE
                                    status.setTextColor(Color.rgb(150, 40, 40))
                                    status.text = "This recovery request expired. Request a new link."
                                }
                            }
                        },
                        onFailure = {
                            status.text = safeMessage(it)
                            mainHandler.postDelayed({ if (screen == recoveryScreen) check() }, 15_000)
                        },
                    )
                }
            }
        }
        refresh.setOnClickListener { check() }
        check()
    }

    private fun showTalkHome(active: DeviceSession) {
        selectedChannel = null
        talkPressed = false
        talkButton = null
        talkStatusView = null
        presenceStatusView = null
        sosButton = null
        sosActive = false
        val content = column()
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(title("PTT Talk"), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(action("Remove device").apply {
            setOnClickListener {
                AlertDialog.Builder(this@TalkActivity)
                    .setTitle("Remove this device?")
                    .setMessage("This revokes its server access and permanently deletes its local encryption keys.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Remove") { _, _ -> removeActiveDevice(active) }
                    .show()
            }
        })
        content.addView(header)
        content.addView(body("Account ${active.aci.take(8)}… · device ${active.deviceId}"))
        val encryption = body("Loading device-key fingerprint…")
        content.addView(encryption)
        armButton =
            action(
                if (PttSessionService.isArmed(this)) "Disconnect background session"
                else "Stay connected",
            ).apply {
                setOnClickListener {
                    if (PttSessionService.isArmed(this@TalkActivity)) {
                        PttSessionService.disarm(this@TalkActivity)
                        text = "Stay connected"
                        talkButton?.isEnabled = false
                    } else {
                        requestSessionPermissionsOrArm()
                    }
                }
            }
        content.addView(requireNotNull(armButton))
        content.addView(body("Background receive is active only after you tap Stay connected; reboot requires another tap."))
        content.addView(title("Presence", 20f))
        val presenceStatus = body("Mode: ${PttSessionService.presenceMode(this).replaceFirstChar { it.uppercase() }}")
        presenceStatusView = presenceStatus
        content.addView(presenceStatus)
        val presenceRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(4), 0, dp(8))
        }
        listOf(
            "available" to "Available",
            "busy" to "Busy",
            "solo" to "Solo",
            "standby" to "Standby",
        ).forEach { (mode, label) ->
            presenceRow.addView(
                action(label).apply {
                    setOnClickListener {
                        PttSessionService.setPresence(this@TalkActivity, mode)
                        presenceStatus.text = if (PttSessionService.isArmed(this@TalkActivity)) {
                            "Mode: $label · updating securely…"
                        } else {
                            "Mode: $label · will publish after Stay connected"
                        }
                    }
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        content.addView(presenceRow)
        content.addView(title("Devices", 20f))
        val deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(deviceList)
        content.addView(action("Link another device").apply { setOnClickListener { showActiveDeviceLink(active) } })
        val connection = body("Connecting securely…")
        content.addView(connection)
        content.addView(action(if (PttSessionService.isOverlayEnabled(this)) "Disable floating PTT" else "Enable floating PTT").apply {
            setOnClickListener {
                if (!PttSessionService.isArmed(this@TalkActivity)) {
                    connection.text = "Tap Stay connected before enabling floating PTT."
                } else if (PttSessionService.isOverlayEnabled(this@TalkActivity)) {
                    PttSessionService.setOverlay(this@TalkActivity, false)
                    text = "Enable floating PTT"
                } else if (!Settings.canDrawOverlays(this@TalkActivity)) {
                    connection.text = "Allow Display over other apps, then tap Enable floating PTT again."
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                } else {
                    PttSessionService.setOverlay(this@TalkActivity, true)
                    text = "Disable floating PTT"
                }
            }
        })
        content.addView(action("Share privacy-redacted support report").apply {
            setOnClickListener { shareSupportReport(active) }
        })
        content.addView(action("Privacy policy and data choices").apply {
            setOnClickListener {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL)))
            }
        })
        content.addView(action("Delete account and server data").apply {
            setOnClickListener {
                AlertDialog.Builder(this@TalkActivity)
                    .setTitle("Permanently delete this account?")
                    .setMessage(
                        "This removes the account from every channel, revokes both devices, " +
                            "de-identifies its email, and deletes local keys and history. " +
                            "Previously delivered ciphertext on teammates' devices cannot be recalled.",
                    )
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Delete account") { _, _ -> deleteActiveAccount(active) }
                    .show()
            }
        })
        content.addView(title("Quick targets", 20f))
        content.addView(body("Tap A/B/C to switch targets. Long-press a slot to assign the selected channel."))
        val quickTargetButtons = listOf("A", "B", "C").associateWith { slot -> action("$slot · Unassigned") }
        val quickTargetRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        quickTargetButtons.values.forEach { button ->
            quickTargetRow.addView(
                button,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        content.addView(quickTargetRow)
        content.addView(title("Channels", 20f))
        content.addView(action("Refresh channels").apply {
            setOnClickListener { showTalkHome(active) }
        })
        val channels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(channels)
        val talkStatus = body("Select a channel to prepare its authenticated floor and relay session.")
        val talk = action("Hold to talk").apply {
            isEnabled = false
            minHeight = dp(88)
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        beginTalk(this, talkStatus)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        endTalk(this, talkStatus)
                        true
                    }
                    else -> false
                }
            }
        }
        talkButton = talk
        talkStatusView = talkStatus
        content.addView(talk)
        content.addView(talkStatus)
        val sos = action("Start priority SOS voice").apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(180, 20, 35))
            setOnClickListener {
                val channel = selectedChannel
                when {
                    channel == null -> talkStatus.text = "Select the emergency channel first."
                    !PttSessionService.isArmed(this@TalkActivity) ->
                        talkStatus.text = "Tap Stay connected before sending an SOS."
                    sosActive -> {
                        sosActive = false
                        text = "Start priority SOS voice"
                        PttSessionService.endTransmit(this@TalkActivity)
                    }
                    else -> confirmEmergency(active, channel, silent = false, talkStatus)
                }
            }
        }
        sosButton = sos
        content.addView(sos)
        content.addView(action("Send silent SOS").apply {
            setOnClickListener {
                val channel = selectedChannel
                when {
                    channel == null -> talkStatus.text = "Select the emergency channel first."
                    !PttSessionService.isArmed(this@TalkActivity) ->
                        talkStatus.text = "Tap Stay connected before sending an SOS."
                    else -> confirmEmergency(active, channel, silent = true, talkStatus)
                }
            }
        })
        content.addView(action("Encrypted history").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) {
                    talkStatus.text = "Select a channel before opening its history."
                } else {
                    showHistory(active, channel)
                }
            }
        })
        content.addView(action("Channel contacts and safety numbers").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) talkStatus.text = "Select a channel before viewing safety numbers."
                else showSafetyNumbers(active, channel)
            }
        })
        val progress = ProgressBar(this)
        content.addView(progress)
        setContentView(scroll(content))

        thread(name = "ptt-load-channels") {
            try {
                val identityFingerprint =
                    EncryptedSignalProtocolStore.open(this).use {
                        fingerprint(it.identityKeyPair.publicKey.serialize())
                    }
                val accountDevices = ControlApi(active.serverUrl).devices(active)
                val available = ControlApi(active.serverUrl).channels(active)
                runOnUiThread {
                    progress.visibility = android.view.View.GONE
                    encryption.text =
                        "Encryption: PQXDH + Double Ratchet authenticated Sender Keys · RFC 9605 SFrame\n" +
                            "This device key: $identityFingerprint"
                    accountDevices.forEach { device ->
                        val deviceRow = LinearLayout(this@TalkActivity).apply {
                            orientation = LinearLayout.VERTICAL
                            addView(body("Device ${device.deviceId} · ${device.displayName} · ${device.status}"))
                            if (device.status == "active" && device.deviceId != active.deviceId) {
                                addView(action("Revoke this linked device").apply {
                                    setOnClickListener {
                                        AlertDialog.Builder(this@TalkActivity)
                                            .setTitle("Revoke ${device.displayName}?")
                                            .setMessage(
                                                "This immediately removes device ${device.deviceId} from the account. " +
                                                    "Affected channel keys will rotate and the device cannot receive future transmissions.",
                                            )
                                            .setNegativeButton("Cancel", null)
                                            .setPositiveButton("Revoke") { _, _ ->
                                                runAction(this, connection) {
                                                    ControlApi(active.serverUrl).revokeDevice(active, device.deviceId)
                                                    runOnUiThread { showTalkHome(active) }
                                                    "Device revoked."
                                                }
                                            }
                                            .show()
                                    }
                                })
                            }
                        }
                        deviceList.addView(deviceRow)
                    }
                    if (available.isEmpty()) {
                        connection.text = "Secure account connection ready"
                        channels.addView(body("No channels yet. Ask an administrator to add you."))
                    } else {
                        val channelRows = mutableMapOf<String, TextView>()
                        available.forEach { channel ->
                            val row = channelRow(channel)
                            row.setOnClickListener {
                                selectChannel(active, channel, row, talk, talkStatus)
                            }
                            channels.addView(row)
                            channelRows[channel.channelId] = row
                        }
                        quickTargetButtons.forEach { (slot, button) ->
                            fun refreshLabel() {
                                val assigned = targetChannelId(slot)
                                val name = available.firstOrNull { it.channelId == assigned }?.displayName
                                button.text = "$slot · ${name ?: "Unassigned"}"
                            }
                            refreshLabel()
                            button.setOnClickListener {
                                val assigned = targetChannelId(slot)
                                val row = assigned?.let(channelRows::get)
                                if (row == null) connection.text = "Long-press $slot to assign the selected channel."
                                else row.performClick()
                            }
                            button.setOnLongClickListener {
                                val selected = selectedChannel
                                if (selected == null) {
                                    connection.text = "Select a channel before assigning quick target $slot."
                                    false
                                } else {
                                    saveTargetChannelId(slot, selected.channelId)
                                    refreshLabel()
                                    connection.text = "Quick target $slot assigned to ${selected.displayName}."
                                    true
                                }
                            }
                        }
                        connection.text = "${available.size} encrypted channel${if (available.size == 1) "" else "s"} ready"
                        (channels.getChildAt(0) as TextView).performClick()
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    progress.visibility = android.view.View.GONE
                    connection.setTextColor(Color.rgb(150, 40, 40))
                    connection.text = safeMessage(error)
                }
            }
        }
    }

    private fun confirmEmergency(
        active: DeviceSession,
        channel: ChannelSummary,
        silent: Boolean,
        status: TextView,
    ) {
        status.text = "Checking emergency recipients…"
        thread(name = "ptt-sos-recipients") {
            val result = runCatching { ControlApi(active.serverUrl).channelDevices(active, channel.channelId) }
            runOnUiThread {
                result.fold(
                    onSuccess = { devices ->
                        val recipients = devices.count { it.aci != active.aci || it.deviceId != active.deviceId }
                        AlertDialog.Builder(this)
                            .setTitle(if (silent) "Send silent SOS?" else "Start priority SOS voice?")
                            .setMessage(
                                "This emergency targets $recipients other active device${if (recipients == 1) "" else "s"} " +
                                    "in ${channel.displayName} and can preempt normal voice.",
                            )
                            .setNegativeButton("Cancel", null)
                            .setPositiveButton(if (silent) "Send SOS" else "Start SOS") { _, _ ->
                                if (!silent) {
                                    sosActive = true
                                    sosButton?.text = "Stop SOS transmission"
                                }
                                status.text = if (silent) "Sending encrypted silent SOS…" else "Requesting priority SOS floor…"
                                PttSessionService.beginEmergency(this, channel, silent)
                            }
                            .show()
                    },
                    onFailure = {
                        status.setTextColor(Color.rgb(150, 40, 40))
                        status.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun showHistory(active: DeviceSession, channel: ChannelSummary) {
        val content = column()
        content.addView(title("Encrypted history"))
        content.addView(body("${channel.displayName} · retained on this device for up to 30 days / 1 GB"))
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val status = body("Loading authenticated recordings…")
        content.addView(rows)
        content.addView(status)
        content.addView(action("Back").apply { setOnClickListener { showTalkHome(active) } })
        setContentView(scroll(content))
        thread(name = "ptt-history-list") {
            val result = runCatching {
                EncryptedSignalProtocolStore.open(this).use { it.historyRecords(channel.channelId) }
            }
            runOnUiThread {
                result.fold(
                    onSuccess = { history ->
                        status.text = if (history.isEmpty()) "No encrypted transmissions saved yet." else "Tap an item to play it securely."
                        history.forEach { item ->
                            val started = item.startedAtMs ?: item.announcedAtMs
                            val whenText = java.text.DateFormat.getDateTimeInstance().format(java.util.Date(started))
                            val sender = if (item.senderAci == active.aci) "You" else "Encrypted teammate"
                            val row = action(
                                "$sender · device ${item.senderDeviceId}\n$whenText · ${(item.durationMs ?: 0) / 1000}s",
                            )
                            row.setOnClickListener {
                                if (!PttSessionService.isArmed(this@TalkActivity)) {
                                    status.text = "Tap Back, then Stay connected before playing history."
                                } else {
                                    status.text = "Starting authenticated history playback…"
                                    PttSessionService.playHistory(this@TalkActivity, item.talkId)
                                }
                            }
                            rows.addView(row)
                        }
                    },
                    onFailure = {
                        status.setTextColor(Color.rgb(150, 40, 40))
                        status.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun showSafetyNumbers(active: DeviceSession, channel: ChannelSummary) {
        val content = column()
        content.addView(title("Safety numbers"))
        content.addView(body("${channel.displayName} · compare these numbers over a trusted channel when a teammate's device key changes."))
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val status = body("Loading authenticated device keys…")
        content.addView(rows)
        content.addView(status)
        content.addView(action("Back").apply { setOnClickListener { showTalkHome(active) } })
        setContentView(scroll(content))
        thread(name = "ptt-safety-numbers") {
            val result = runCatching {
                val local = EncryptedSignalProtocolStore.open(this).use {
                    it.identityKeyPair.publicKey.serialize()
                }
                ControlApi(active.serverUrl).channelDevices(active, channel.channelId)
                    .filter { it.aci != active.aci || it.deviceId != active.deviceId }
                    .map { device ->
                        val ordered = listOf(local, device.identityKey).sortedWith { left, right -> compareBytes(left, right) }
                        val digest = MessageDigest.getInstance("SHA-512").digest(ordered[0] + ordered[1])
                        val number = digest.take(20).joinToString("") { "%03d".format(it.toInt() and 0xff) }
                            .chunked(5).joinToString(" ")
                        Triple(device.aci, device.deviceId, number)
                    }
            }
            runOnUiThread {
                result.fold(
                    onSuccess = { values ->
                        status.text = if (values.isEmpty()) "No other active devices are in this channel." else "Safety numbers are derived locally; raw identity keys are never displayed."
                        values.forEach { (aci, deviceId, number) ->
                            rows.addView(body("Encrypted teammate ${aci.take(8)}… · device $deviceId\n$number"))
                        }
                    },
                    onFailure = { status.text = safeMessage(it) },
                )
            }
        }
    }

    private fun compareBytes(left: ByteArray, right: ByteArray): Int {
        for (index in 0 until minOf(left.size, right.size)) {
            val compared = (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
            if (compared != 0) return compared
        }
        return left.size.compareTo(right.size)
    }

    private fun targetChannelId(slot: String): String? =
        getSharedPreferences("ptt-quick-targets-v1", Context.MODE_PRIVATE)
            .getString("slot-$slot", null)

    private fun saveTargetChannelId(slot: String, channelId: String) {
        require(slot in setOf("A", "B", "C"))
        getSharedPreferences("ptt-quick-targets-v1", Context.MODE_PRIVATE)
            .edit()
            .putString("slot-$slot", channelId)
            .apply()
    }

    private fun showActiveDeviceLink(active: DeviceSession) {
        val content = column()
        content.addView(title("Link another device"))
        content.addView(body("Generate a one-time code, enter it on the new device, then return here to approve."))
        val details = body("")
        val start = action("Generate link code")
        val approve = action("Approve claimed device").apply { isEnabled = false }
        val status = body("")
        content.addView(start)
        content.addView(details)
        content.addView(approve)
        content.addView(status)
        content.addView(action("Back").apply { setOnClickListener { showTalkHome(active) } })
        var pendingRequestId: String? = null
        start.setOnClickListener {
            runAction(start, status) {
                val link = ControlApi(active.serverUrl).startDeviceLink(active)
                pendingRequestId = link.requestId
                runOnUiThread {
                    details.text = "Request ID\n${link.requestId}\n\nOne-time code\n${link.linkCode}"
                    approve.isEnabled = true
                }
                "Code generated. It expires in 10 minutes."
            }
        }
        approve.setOnClickListener {
            runAction(approve, status) {
                ControlApi(active.serverUrl).approveDeviceLink(active, requireNotNull(pendingRequestId))
                runOnUiThread { showTalkHome(active) }
                "Device approved."
            }
        }
        setContentView(scroll(content))
    }

    private fun channelRow(channel: ChannelSummary): TextView =
        body("${channel.displayName}\n${channel.role} · ${channel.kind} · key epoch ${channel.membershipEpoch}").apply {
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setBackgroundColor(Color.rgb(238, 248, 244))
        }

    private fun selectChannel(
        active: DeviceSession,
        channel: ChannelSummary,
        row: TextView,
        talk: Button,
        status: TextView,
    ) {
        selectedChannel = channel
        talk.isEnabled = false
        status.setTextColor(Color.DKGRAY)
        status.text = "Preparing ${channel.displayName} securely…"
        (row.parent as? LinearLayout)?.let { parent ->
            repeat(parent.childCount) { index ->
                parent.getChildAt(index).setBackgroundColor(
                    if (parent.getChildAt(index) === row) Color.rgb(212, 241, 231)
                    else Color.rgb(238, 248, 244),
                )
            }
        }
        if (PttSessionService.isArmed(this)) {
            PttSessionService.prepare(this, channel)
        } else {
            status.text = "Tap Stay connected to enable encrypted voice for ${channel.displayName}."
        }
    }

    private fun beginTalk(button: Button, status: TextView) {
        val channel = selectedChannel ?: return
        if (!PttSessionService.isArmed(this)) {
            status.text = "Tap Stay connected and allow microphone access before talking."
            return
        }
        if (talkPressed) return
        talkPressed = true
        button.text = "Requesting floor…"
        status.text = "Waiting for an authenticated floor grant…"
        PttSessionService.beginTransmit(this, channel)
    }

    private fun endTalk(button: Button, status: TextView) {
        if (!talkPressed) return
        talkPressed = false
        button.text = "Hold to talk"
        status.setTextColor(Color.DKGRAY)
        status.text = "Releasing floor…"
        tones.released()
        PttSessionService.endTransmit(this)
    }

    private fun runAction(button: Button, status: TextView, operation: () -> String) {
        button.isEnabled = false
        status.setTextColor(Color.DKGRAY)
        status.text = "Working securely…"
        thread(name = "ptt-account-action") {
            val result = runCatching(operation)
            runOnUiThread {
                button.isEnabled = true
                status.setTextColor(if (result.isSuccess) Color.rgb(8, 117, 92) else Color.rgb(150, 40, 40))
                status.text = result.fold({ it }, ::safeMessage)
            }
        }
    }

    private fun removeActiveDevice(active: DeviceSession) {
        val content = column()
        content.addView(title("Removing device"))
        val status = body("Revoking server access…")
        content.addView(status)
        content.addView(ProgressBar(this))
        setContentView(scroll(content))
        thread(name = "ptt-revoke-device") {
            val result =
                runCatching {
                    ControlApi(active.serverUrl).revokeThisDevice(active)
                    PttSessionService.disarm(this)
                    EncryptedSignalProtocolStore.resetLocalDeviceState(this)
                    credentials.clear()
                    credentials.saveServer(active.serverUrl)
                }
            runOnUiThread {
                result.fold(
                    onSuccess = {
                        recoveryScreen++
                        session = null
                        showOnboarding()
                    },
                    onFailure = {
                        status.setTextColor(Color.rgb(150, 40, 40))
                        status.text = safeMessage(it)
                        content.addView(action("Return").apply { setOnClickListener { showTalkHome(active) } })
                    },
                )
            }
        }
    }

    private fun deleteActiveAccount(active: DeviceSession) {
        val content = column()
        content.addView(title("Deleting account"))
        val status = body("Removing server data and rotating channel keys…")
        content.addView(status)
        content.addView(ProgressBar(this))
        setContentView(scroll(content))
        thread(name = "ptt-delete-account") {
            val result =
                runCatching {
                    ControlApi(active.serverUrl).deleteAccount(active)
                    PttSessionService.disarm(this)
                    EncryptedSignalProtocolStore.resetLocalDeviceState(this)
                    credentials.clear()
                    credentials.saveServer(active.serverUrl)
                }
            runOnUiThread {
                result.fold(
                    onSuccess = {
                        recoveryScreen++
                        session = null
                        showOnboarding()
                    },
                    onFailure = {
                        status.setTextColor(Color.rgb(150, 40, 40))
                        status.text = safeMessage(it)
                        content.addView(action("Return").apply { setOnClickListener { showTalkHome(active) } })
                    },
                )
            }
        }
    }

    private fun safeMessage(error: Throwable): String =
        when (error) {
            is ControlApiException -> when (error.code) {
                "INVALID_OR_EXPIRED_LINK" -> "That link expired or was already used. Request another."
                "DEVICE_LINK_APPROVAL_REQUIRED" -> "This account already exists. Link from an active device or use recovery."
                "RECOVERY_NOT_PENDING" -> "That recovery request is no longer pending."
                else -> "The server rejected the request (${error.code})."
            }
            is IllegalArgumentException, is IllegalStateException -> error.message ?: "The request is invalid."
            else -> "Could not reach the private-team server."
        }

    private fun shareSupportReport(active: DeviceSession) {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val transports = buildList {
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) add("wifi")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true) add("cellular")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true) add("ethernet")
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) add("vpn")
        }.ifEmpty { listOf("offline-or-unknown") }
        val accountFingerprint =
            MessageDigest.getInstance("SHA-256")
                .digest(active.aci.lowercase().encodeToByteArray())
                .take(6)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val report = buildString {
            appendLine("PTT Talk privacy-redacted support report")
            appendLine("App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            appendLine("Android: ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT}")
            appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
            appendLine("Account fingerprint: $accountFingerprint")
            appendLine("Network: ${transports.joinToString(",")}")
            appendLine("Background session armed: ${PttSessionService.isArmed(this@TalkActivity)}")
            appendLine("Floating PTT enabled: ${PttSessionService.isOverlayEnabled(this@TalkActivity)}")
            appendLine("Selected channel role: ${selectedChannel?.role ?: "none"}")
            appendLine("Selected channel epoch: ${selectedChannel?.membershipEpoch ?: 0}")
            appendLine("Excluded: email, server URL, account/device/mailbox IDs, tokens, keys, audio, channel IDs, and message contents")
        }
        startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(Intent.EXTRA_SUBJECT, "PTT Talk support report")
                    .putExtra(Intent.EXTRA_TEXT, report),
                "Share support report",
            ),
        )
    }

    private fun requestSessionPermissionsOrArm() {
        val missing = buildList {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.RECORD_AUDIO)
            }
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (missing.isEmpty()) {
            PttSessionService.arm(this)
            armButton?.text = "Disconnect background session"
            selectedChannel?.let { PttSessionService.prepare(this, it) }
        } else {
            requestPermissions(missing.toTypedArray(), REQUEST_ARM_PERMISSIONS)
        }
    }

    private fun column(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(36))
            setBackgroundColor(Color.WHITE)
            setOnApplyWindowInsetsListener { view, insets ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val bars = insets.getInsets(WindowInsets.Type.systemBars())
                    view.setPadding(dp(18) + bars.left, dp(18) + bars.top, dp(18) + bars.right, dp(36) + bars.bottom)
                }
                insets
            }
        }

    private fun scroll(content: LinearLayout): ScrollView = ScrollView(this).apply { addView(content) }

    private fun title(value: String, size: Float = 28f): TextView = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(Color.rgb(19, 32, 28))
        setPadding(0, dp(8), 0, dp(8))
    }

    private fun body(value: String): TextView = TextView(this).apply {
        text = value
        textSize = 15f
        setTextColor(Color.DKGRAY)
        setPadding(0, dp(7), 0, dp(7))
    }

    private fun field(hint: String, value: String = "", secret: Boolean = false): EditText = EditText(this).apply {
        this.hint = hint
        setText(value)
        if (secret) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        setSingleLine(true)
        setPadding(dp(12), dp(12), dp(12), dp(12))
    }

    private fun action(label: String): Button = Button(this).apply {
        text = label
        isAllCaps = false
        setPadding(dp(12), dp(12), dp(12), dp(12))
    }

    private fun defaultServer(): String =
        configuredServer
            ?: intent.getStringExtra("ptt_server")
            ?: if (BuildConfig.DEBUG) "http://10.0.2.2:8080" else "https://ptt.example.com"

    private fun defaultDeviceName(): String =
        "${Build.MANUFACTURER} ${Build.MODEL}".trim().take(80).ifBlank {
            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: "Android device"
        }

    private fun localIdentity(): IdentityKeyPair =
        try {
            EncryptedSignalProtocolStore.open(this).use { it.identityKeyPair }
        } catch (_: IllegalStateException) {
            val identity = IdentityKeyPair.generate()
            EncryptedSignalProtocolStore.open(
                this,
                identity,
                KeyHelper.generateRegistrationId(false),
            ).close()
            identity
        }

    private fun fingerprint(value: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value)
            .take(12)
            .joinToString("") { "%02X".format(it.toInt() and 0xff) }
            .chunked(4)
            .joinToString(" ")

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val REQUEST_ARM_PERMISSIONS = 4102
        const val PRIVACY_POLICY_URL = "https://golanbenoni.github.io/ptt-talk-privacy/#deletion"
    }
}
