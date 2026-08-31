package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.BroadcastReceiver
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.media.MediaRecorder
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.OpenableColumns
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.security.MessageDigest
import java.util.UUID
import kotlin.concurrent.thread
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.util.KeyHelper

/** Production application shell. The legacy encrypted-tone fixture lives in tools/net. */
class TalkActivity : Activity() {
    private lateinit var credentials: SecureDeviceStore
    private var session: DeviceSession? = null
    private var incomingAction: String? = null
    private var incomingToken: String? = null
    private var incomingDeviceInvite: DeviceLinkInvite? = null
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
    private var pendingChatChannel: ChannelSummary? = null
    private var pendingChatKind: ChatContentKind = ChatContentKind.FILE
    private var chatRecorder: MediaRecorder? = null
    private var chatRecorderFile: java.io.File? = null
    private var chatRecorderStartedAt = 0L
    private var chatRecorderPaused = false
    private var chatRecorderLocked = false
    private var chatRecorderPausedAt = 0L
    private var chatRecorderPausedTotal = 0L
    private var chatRecorderMeterTask: Runnable? = null
    private val chatRecorderSamples = mutableListOf<Byte>()
    private var chatPendingVoiceFile: java.io.File? = null
    private var chatPendingVoiceDurationMs = 0
    private var chatPendingVoiceWaveform = byteArrayOf()
    private var chatVoicePlayer: MediaPlayer? = null
    private var chatVoiceMessageId: UUID? = null
    private var chatVoicePlaybackRate = 1f
    private var chatVoicePlaybackFile: java.io.File? = null
    private var chatReplyTo: UUID? = null
    private var chatEditing: UUID? = null
    private var openChatRequested = false
    private var requestedChatChannelId: String? = null
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
                        talkStatusView?.setTextColor(colorSuccess())
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_GRANTED -> {
                        talkButton?.isEnabled = true
                        talkButton?.text = "Floor granted — securing…"
                        talkStatusView?.setTextColor(colorSuccess())
                        if (!detail.startsWith("Silent SOS")) tones.granted()
                    }
                    PttSessionService.STATE_TRANSMITTING -> {
                        talkButton?.isEnabled = true
                        talkButton?.text = "Floor granted — talking"
                        talkStatusView?.setTextColor(colorSuccess())
                    }
                    PttSessionService.STATE_DENIED -> {
                        talkPressed = false
                        talkButton?.isEnabled = true
                        talkButton?.text = "Hold to talk"
                        talkStatusView?.setTextColor(colorDanger())
                        tones.denied()
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_ERROR -> {
                        talkPressed = false
                        talkButton?.isEnabled = selectedChannel != null && PttSessionService.isArmed(this@TalkActivity)
                        talkButton?.text = "Hold to talk"
                        talkStatusView?.setTextColor(colorDanger())
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
                        talkStatusView?.setTextColor(if (emergency) colorDanger() else colorSuccess())
                        if (emergency) tones.emergency()
                    }
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.statusBarColor = colorBackground()
        window.navigationBarColor = colorBackground()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            window.decorView.systemUiVisibility =
                if (isDarkTheme()) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
        credentials = SecureDeviceStore(this)
        configuredServer = intent.getStringExtra("ptt_server") ?: credentials.loadServer()
        session = credentials.load()
        openChatRequested = intent.getBooleanExtra(PttMessagingService.EXTRA_OPEN_CHAT, false)
        requestedChatChannelId = intent.getStringExtra(PttMessagingService.EXTRA_CHAT_CHANNEL_ID)
        acceptDeepLink(intent)
        when {
            session != null -> showTalkHome(requireNotNull(session))
            credentials.loadPendingLink() != null -> showPendingDeviceLink(requireNotNull(credentials.loadPendingLink()))
            credentials.loadPending() != null -> showPendingRecovery(requireNotNull(credentials.loadPending()))
            incomingDeviceInvite != null -> showIncomingDeviceLink(requireNotNull(incomingDeviceInvite))
            incomingAction == "recover" -> showRecovery()
            else -> showOnboarding()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openChatRequested = openChatRequested || intent.getBooleanExtra(PttMessagingService.EXTRA_OPEN_CHAT, false)
        intent.getStringExtra(PttMessagingService.EXTRA_CHAT_CHANNEL_ID)?.let { requestedChatChannelId = it }
        acceptDeepLink(intent)
        if (session == null) {
            when {
                incomingDeviceInvite != null -> showIncomingDeviceLink(requireNotNull(incomingDeviceInvite))
                incomingAction == "recover" -> showRecovery()
                else -> showOnboarding()
            }
        } else if (openChatRequested) {
            selectedChannel?.let {
                openChatRequested = false
                showChat(requireNotNull(session), it)
            } ?: showTalkHome(requireNotNull(session))
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
        stopChatVoicePlayback()
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

    @Deprecated("Activity result API retained for the programmatic no-AndroidX shell")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CHAT_ATTACHMENT || resultCode != RESULT_OK) return
        val active = session ?: return
        val channel = pendingChatChannel ?: return
        val uri = data?.data ?: return
        val kind = pendingChatKind
        pendingChatChannel = null
        thread(name = "ptt-chat-attachment-send") {
            val result = runCatching {
                val bytes = readBoundedChatAttachment(uri)
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: "Attachment"
                val mime = contentResolver.getType(uri) ?: "application/octet-stream"
                EncryptedChatClient(this, active).sendAttachment(bytes, name, mime, kind, channel = channel)
            }
            runOnUiThread {
                result.fold(
                    onSuccess = { showChat(active, channel, "Attachment sent securely.") },
                    onFailure = { showChat(active, channel, safeMessage(it)) },
                )
            }
        }
    }

    private fun readBoundedChatAttachment(uri: Uri): ByteArray {
        val input = contentResolver.openInputStream(uri) ?: error("Attachment is unavailable")
        return input.use {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                require(output.size() + count <= EncryptedChatCodec.MAX_ATTACHMENT_BYTES) {
                    "Attachments must be 25 MB or smaller"
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private fun acceptDeepLink(intent: Intent) {
        val data = intent.data ?: return
        deviceLinkInvite(data.toString())?.let {
            if (session == null) {
                incomingDeviceInvite = it
                configuredServer = it.serverUrl
            }
            return
        }
        if (data.scheme != "https" || data.host != "ptttalk.app" || data.path !in setOf("/enroll", "/recover")) return
        if (session != null) return
        incomingAction = data.lastPathSegment
        incomingToken = oneTimeToken(data)?.takeIf { it.length in 32..256 }
        configuredServer = "https://ptttalk.app"
    }

    private fun oneTimeToken(data: android.net.Uri): String? {
        data.getQueryParameter("token")?.let { return it }
        val fragment = data.fragment ?: return null
        return android.net.Uri.parse("https://token.invalid/?$fragment").getQueryParameter("token")
    }

    private fun showOnboarding() {
        incomingDeviceInvite?.let {
            showIncomingDeviceLink(it)
            return
        }
        if (incomingAction == "enroll" && !incomingToken.isNullOrBlank()) {
            showIncomingEnrollment()
            return
        }
        val content = column()
        content.addView(brandMark())
        content.addView(sectionTitle("Private voice for your team"))
        content.addView(body("Open your team invitation on this phone. PTT Talk handles the server connection and creates your encryption keys automatically."))
        val invitation = card()
        invitation.addView(sectionTitle("Open your team invite", "GET STARTED"))
        invitation.addView(stepRow(1, "Open the invitation email", "Use the email address your administrator invited."))
        invitation.addView(stepRow(2, "Tap Join PTT Talk", "The invite securely configures this device for you."))
        invitation.addView(stepRow(3, "Choose a channel and talk", "Hold the talk button while you speak, then release."))
        val openEmail = primaryAction("Open email")
        invitation.addView(openEmail)
        addCard(content, invitation)
        val alternatives = card()
        alternatives.addView(sectionTitle("Other ways to continue"))
        alternatives.addView(action("Enter invite manually  ›").apply { setOnClickListener { showManualInvitation() } })
        alternatives.addView(action("Link a second device  ›").apply { setOnClickListener { showDeviceLinkClaim() } })
        alternatives.addView(action("Recover an account  ›").apply { setOnClickListener { showRecovery() } })
        addCard(content, alternatives)
        openEmail.setOnClickListener {
            runCatching { startActivity(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_EMAIL)) }
        }
        setContentView(scroll(content))
    }

    private fun showManualInvitation() {
        val content = column()
        content.addView(sectionTitle("Enter invitation details", "MANUAL SETUP"))
        content.addView(body("Use this fallback only if your administrator gave you a code instead of sending the invitation email."))
        val server = field("Server URL", defaultServer())
        val email = field("Email address")
        val invitation = field("Invitation code", secret = true)
        val enrollment = card()
        enrollment.addView(sectionTitle("Request your sign-in email", "STEP 1 OF 2"))
        enrollment.addView(body("Enter the team server, your email, and the invitation code exactly as your administrator sent them."))
        enrollment.addView(body("Team server address"))
        enrollment.addView(server)
        enrollment.addView(body("Your invited email address"))
        enrollment.addView(email)
        enrollment.addView(body("Invitation code"))
        enrollment.addView(invitation)
        val requestLink = primaryAction("Send sign-in email")
        enrollment.addView(requestLink)
        val status = body("")
        enrollment.addView(status)
        addCard(content, enrollment)
        content.addView(action("Back").apply { setOnClickListener { showOnboarding() } })

        requestLink.setOnClickListener {
            runAction(requestLink, status) {
                require(email.text.toString().contains('@')) { "Enter your email address." }
                require(invitation.text.isNotBlank()) { "Enter the invitation code." }
                configuredServer = server.text.toString().trimEnd('/')
                ControlApi(server.text.toString()).requestMagicLink(
                    email.text.toString().trim(),
                    invitation.text.toString().trim(),
                )
                runOnUiThread { showEnrollmentEmailSent(email.text.toString().trim()) }
                "Sign-in email sent."
            }
        }
        setContentView(scroll(content))
    }

    private fun showEnrollmentEmailSent(email: String) {
        val content = column()
        content.addView(sectionTitle("Check your email", "STEP 2 OF 2"))
        content.addView(statusPill("●  Sign-in email sent"))
        content.addView(body("We sent a one-time sign-in link to $email."))
        val instructions = card()
        instructions.addView(sectionTitle("Finish on this device", "WHAT TO DO NEXT"))
        instructions.addView(body("1. Open the email on this phone.\n2. Tap Join PTT Talk.\n3. Return here automatically—there is no code to copy."))
        val openEmail = primaryAction("Open email")
        instructions.addView(openEmail)
        instructions.addView(action("Paste a code instead").apply { setOnClickListener { showManualEnrollment() } })
        addCard(content, instructions)
        content.addView(action("Use a different invitation").apply { setOnClickListener { showOnboarding() } })
        openEmail.setOnClickListener {
            runCatching { startActivity(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_EMAIL)) }
        }
        setContentView(scroll(content))
    }

    private fun showManualEnrollment() {
        val content = column()
        content.addView(sectionTitle("Enter your one-time code", "MANUAL SIGN-IN"))
        content.addView(body("Most people can open the email link instead. Use this only if the link opened on another device."))
        val form = card()
        val server = field("Server URL", defaultServer())
        val token = field("One-time code", incomingToken.orEmpty(), secret = true)
        form.addView(body("Team server address"))
        form.addView(server)
        form.addView(body("Code from the sign-in email"))
        form.addView(token)
        val complete = primaryAction("Join this team")
        val status = body("")
        form.addView(complete)
        form.addView(status)
        addCard(content, form)
        content.addView(action("Back").apply { setOnClickListener { showOnboarding() } })
        complete.setOnClickListener {
            completeEnrollment(server.text.toString(), token.text.toString(), complete, status)
        }
        setContentView(scroll(content))
    }

    private fun completeEnrollment(serverUrl: String, token: String, button: Button, status: TextView) {
        runAction(button, status) {
            val magicToken = token.trim()
            require(magicToken.isNotBlank()) { "Enter the one-time code from your email." }
            configuredServer = serverUrl.trimEnd('/')
            val identity = localIdentity()
            val enrolled =
                ControlApi(serverUrl).consumeMagicLink(
                    magicToken,
                    defaultDeviceName(),
                    identity.publicKey.serialize(),
                    credentials.enrollmentResumeSecret(),
                )
            credentials.save(enrolled)
            credentials.clearEnrollmentResumeSecret()
            session = enrolled
            incomingToken = null
            incomingAction = null
            runOnUiThread { showTalkHome(enrolled) }
            "Enrollment complete."
        }
    }

    private fun showIncomingEnrollment() {
        val token = incomingToken.orEmpty()
        val content = column()
        content.addView(sectionTitle("Joining your team", "SECURE DEVICE SETUP"))
        content.addView(body("PTT Talk is verifying the one-time link and creating encryption keys for this device."))
        val status = body("Securing this device…")
        val progress = ProgressBar(this)
        val retry = primaryAction("Try again").apply { visibility = View.GONE }
        content.addView(status)
        content.addView(progress)
        content.addView(retry)
        content.addView(action("Use a different invitation").apply { setOnClickListener {
            incomingToken = null
            incomingAction = null
            showOnboarding()
        } })
        setContentView(scroll(content))

        fun attempt() {
            retry.visibility = View.GONE
            progress.visibility = View.VISIBLE
            status.setTextColor(colorMuted())
            status.text = "Securing this device…"
            thread(name = "ptt-enrollment") {
                val result = runCatching {
                    val identity = localIdentity()
                    ControlApi(defaultServer()).consumeMagicLink(
                        token,
                        defaultDeviceName(),
                        identity.publicKey.serialize(),
                        credentials.enrollmentResumeSecret(),
                    )
                }
                runOnUiThread {
                    result.fold(
                        onSuccess = { enrolled ->
                            credentials.save(enrolled)
                            credentials.clearEnrollmentResumeSecret()
                            session = enrolled
                            incomingToken = null
                            incomingAction = null
                            showTalkHome(enrolled)
                        },
                        onFailure = {
                            progress.visibility = View.GONE
                            retry.visibility = View.VISIBLE
                            status.setTextColor(colorDanger())
                            status.text = safeMessage(it)
                        },
                    )
                }
            }
        }
        retry.setOnClickListener { attempt() }
        attempt()
    }

    private fun showDeviceLinkClaim() {
        recoveryScreen++
        val content = column()
        content.addView(title("Link this device"))
        content.addView(body("Normally, send the setup link from Settings on your current device and open it here. Use these fields only when the link cannot open PTT Talk."))
        val server = field("Server URL", defaultServer())
        val requestId = field("Link request ID")
        val linkCode = field("One-time link code", secret = true)
        content.addView(server)
        content.addView(requestId)
        content.addView(linkCode)
        val claim = primaryAction("Continue with the manual codes")
        val status = body("")
        content.addView(claim)
        content.addView(status)
        content.addView(action("Back to enrollment").apply { setOnClickListener { showOnboarding() } })
        claim.setOnClickListener {
            runAction(claim, status) {
                require(requestId.text.isNotBlank()) { "Enter the request ID from the active device." }
                require(linkCode.text.isNotBlank()) { "Enter the one-time link code." }
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
                        defaultDeviceName(),
                        identity.publicKey.serialize(),
                    )
                credentials.savePendingLink(pending)
                runOnUiThread { showPendingDeviceLink(pending) }
                "Approval requested."
            }
        }
        setContentView(scroll(content))
    }

    private fun showIncomingDeviceLink(invite: DeviceLinkInvite) {
        incomingDeviceInvite = null
        val screen = ++recoveryScreen
        val content = column()
        content.addView(title("Adding this device"))
        content.addView(body("The private setup link filled in your team details. PTT Talk is now creating a separate encryption identity for this device."))
        val progress = ProgressBar(this)
        val status = body("Preparing secure device keys…")
        val retry = primaryAction("Try again").apply { visibility = View.GONE }
        content.addView(progress)
        content.addView(status)
        content.addView(retry)
        content.addView(action("Cancel").apply { setOnClickListener { showOnboarding() } })
        setContentView(scroll(content))

        fun attempt() {
            progress.visibility = View.VISIBLE
            retry.visibility = View.GONE
            status.setTextColor(colorMuted())
            status.text = "Preparing secure device keys…"
            thread(name = "ptt-device-link") {
                val result = runCatching {
                    configuredServer = invite.serverUrl
                    EncryptedSignalProtocolStore.resetLocalDeviceState(this)
                    val identity = IdentityKeyPair.generate()
                    EncryptedSignalProtocolStore.open(
                        this,
                        identity,
                        KeyHelper.generateRegistrationId(false),
                    ).close()
                    ControlApi(invite.serverUrl).claimDeviceLink(
                        invite.requestId,
                        invite.linkCode,
                        defaultDeviceName(),
                        identity.publicKey.serialize(),
                    )
                }
                runOnUiThread {
                    if (screen != recoveryScreen || isFinishing || isDestroyed) return@runOnUiThread
                    result.fold(
                        onSuccess = { pending ->
                            credentials.savePendingLink(pending)
                            showPendingDeviceLink(pending)
                        },
                        onFailure = {
                            progress.visibility = View.GONE
                            retry.visibility = View.VISIBLE
                            status.setTextColor(colorDanger())
                            status.text = safeMessage(it)
                        },
                    )
                }
            }
        }
        retry.setOnClickListener { attempt() }
        attempt()
    }

    private fun showPendingDeviceLink(pending: PendingDeviceLink) {
        val screen = ++recoveryScreen
        val content = column()
        content.addView(title("Device approval pending"))
        content.addView(body("This device is ready. Return to your current device and tap Approve new device."))
        val status = body("Waiting for the active device…")
        val progress = ProgressBar(this)
        val refresh = primaryAction("Check now")
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
        if (incomingAction == "recover" && !incomingToken.isNullOrBlank()) {
            showRecoveryApproval()
            return
        }
        recoveryScreen++
        val content = column()
        content.addView(sectionTitle("Recover your account", "NO ACTIVE DEVICE"))
        content.addView(
            body(
                "Use this only if you no longer have an active device. We'll email a recovery link, then a different team administrator must approve the replacement.",
            ),
        )
        val server = field("Server URL", defaultServer())
        val email = field("Account email")
        content.addView(server)
        content.addView(email)
        val request = primaryAction("Send recovery email")
        content.addView(request)
        val status = body("")
        content.addView(status)
        content.addView(action("Back").apply { setOnClickListener { showOnboarding() } })

        request.setOnClickListener {
            runAction(request, status) {
                require(email.text.toString().contains('@')) { "Enter your account email address." }
                configuredServer = server.text.toString().trimEnd('/')
                ControlApi(server.text.toString()).requestRecovery(email.text.toString().trim())
                runOnUiThread { showRecoveryEmailSent(email.text.toString().trim()) }
                "Recovery email sent."
            }
        }
        setContentView(scroll(content))
    }

    private fun showRecoveryEmailSent(email: String) {
        val content = column()
        content.addView(sectionTitle("Check your email", "RECOVERY"))
        content.addView(statusPill("●  Recovery email requested"))
        content.addView(body("If the account exists, we sent a one-time recovery link to $email. Open it on this phone to continue."))
        val openEmail = primaryAction("Open email")
        content.addView(openEmail)
        content.addView(action("Use a different account").apply { setOnClickListener { showRecovery() } })
        content.addView(action("Back to sign in").apply { setOnClickListener { showOnboarding() } })
        openEmail.setOnClickListener {
            runCatching { startActivity(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_EMAIL)) }
        }
        setContentView(scroll(content))
    }

    private fun showRecoveryApproval() {
        recoveryScreen++
        val content = column()
        content.addView(sectionTitle("Recovery email verified", "ADMIN APPROVAL REQUIRED"))
        content.addView(body("Continuing creates replacement keys for this device and asks a different team administrator to approve them. Approval revokes the old devices and rotates channel keys."))
        val submit = primaryAction("Request administrator approval")
        val status = body("")
        content.addView(submit)
        content.addView(status)
        content.addView(action("Cancel recovery").apply { setOnClickListener {
            incomingToken = null
            incomingAction = null
            showOnboarding()
        } })
        submit.setOnClickListener {
            runAction(submit, status) {
                val recoveryToken = incomingToken.orEmpty().trim()
                require(recoveryToken.isNotBlank()) { "Open a fresh recovery email link on this device." }
                configuredServer = defaultServer().trimEnd('/')

                // Recovery is the one flow allowed to replace local cryptographic identity. It is
                // explicit here and paired with server-side revocation of every former device.
                EncryptedSignalProtocolStore.resetForAccountRecovery(this)
                val identity = IdentityKeyPair.generate()
                val registrationId = KeyHelper.generateRegistrationId(false)
                EncryptedSignalProtocolStore.open(this, identity, registrationId).close()
                val api = ControlApi(defaultServer())
                val claim =
                    api.consumeRecovery(
                        recoveryToken,
                        defaultDeviceName(),
                        identity.publicKey.serialize(),
                    )
                val pending = PendingRecovery(defaultServer().trimEnd('/'), claim.requestId, claim.claimToken)
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
        val refresh = primaryAction("Check now")
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
                                    status.setTextColor(colorDanger())
                                    status.text = "The administrator denied this recovery request."
                                }
                                else -> {
                                    progress.visibility = android.view.View.GONE
                                    status.setTextColor(colorDanger())
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
        content.addView(sectionTitle("PTT Talk", "ENCRYPTED TEAM VOICE"))
        content.addView(statusPill("●  Account ${active.aci.take(8)}…  ·  Device ${active.deviceId} of 2"))

        val voiceCard = card()
        voiceCard.addView(sectionTitle("Live channel", "READY WHEN YOU ARE"))
        val connection = statusPill("Connecting securely…")
        voiceCard.addView(connection)
        armButton =
            primaryAction(
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
        voiceCard.addView(requireNotNull(armButton))
        voiceCard.addView(body("Stay connected keeps encrypted receive armed while the screen is off. After a reboot, tap it again."))

        val channelHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        channelHeader.addView(title("Talk target", 18f), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val refreshChannels = action("Refresh").apply {
            minHeight = dp(44)
            setOnClickListener { showTalkHome(active) }
        }
        channelHeader.addView(
            refreshChannels,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT),
        )
        voiceCard.addView(channelHeader)
        val channels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        voiceCard.addView(channels)

        val quickTargetButtons = listOf("A", "B", "C").associateWith { slot -> action("$slot · Unassigned") }
        val quickTargetRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(5), 0, dp(5))
        }
        quickTargetButtons.values.forEach { button ->
            quickTargetRow.addView(
                button,
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    setMargins(dp(3), 0, dp(3), 0)
                },
            )
        }
        voiceCard.addView(body("Quick targets · tap to switch, hold to assign"))
        voiceCard.addView(quickTargetRow)

        val talkStatus = statusPill("Select a channel to prepare its authenticated floor and relay session.")
        val talk = primaryAction("Hold to talk").apply {
            isEnabled = false
            minHeight = dp(116)
            textSize = 20f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            contentDescription = "Hold to talk. Release to stop."
            background = rounded(colorAccent(), 28f)
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        animate().scaleX(0.98f).scaleY(0.98f).setDuration(90).start()
                        beginTalk(this, talkStatus)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                        endTalk(this, talkStatus)
                        true
                    }
                    else -> false
                }
            }
        }
        talkButton = talk
        talkStatusView = talkStatus
        voiceCard.addView(talk)
        voiceCard.addView(talkStatus)

        val sos = dangerAction("Start priority SOS voice").apply {
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
        val silentSos = action("Send silent SOS").apply {
            setTextColor(colorDanger())
            setOnClickListener {
                val channel = selectedChannel
                when {
                    channel == null -> talkStatus.text = "Select the emergency channel first."
                    !PttSessionService.isArmed(this@TalkActivity) ->
                        talkStatus.text = "Tap Stay connected before sending an SOS."
                    else -> confirmEmergency(active, channel, silent = true, talkStatus)
                }
            }
        }
        val emergencyRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        emergencyRow.addView(sos, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            setMargins(0, dp(4), dp(4), dp(4))
        })
        emergencyRow.addView(silentSos, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            setMargins(dp(4), dp(4), 0, dp(4))
        })
        voiceCard.addView(emergencyRow)

        val history = action("Encrypted history").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) talkStatus.text = "Select a channel before opening its history."
                else showHistory(active, channel)
            }
        }
        val chat = action("Encrypted chat").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) talkStatus.text = "Select a channel before opening chat."
                else showChat(active, channel)
            }
        }
        val safety = action("Contacts & safety numbers").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) talkStatus.text = "Select a channel before viewing safety numbers."
                else showSafetyNumbers(active, channel)
            }
        }
        val utilityRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        utilityRow.addView(history, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            setMargins(0, dp(4), dp(4), 0)
        })
        utilityRow.addView(safety, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            setMargins(dp(4), dp(4), 0, 0)
        })
        voiceCard.addView(utilityRow)
        voiceCard.addView(chat)
        val progress = ProgressBar(this).apply {
            indeterminateTintList = ColorStateList.valueOf(colorAccent())
            contentDescription = "Loading secure channel"
        }
        voiceCard.addView(progress)
        addCard(content, voiceCard)

        val presenceCard = card()
        presenceCard.addView(sectionTitle("Presence", "AVAILABILITY"))
        val presenceStatus = body("Mode: ${PttSessionService.presenceMode(this).replaceFirstChar { it.uppercase() }}")
        presenceStatusView = presenceStatus
        presenceCard.addView(presenceStatus)
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
                    textSize = 13f
                    setPadding(dp(4), dp(12), dp(4), dp(12))
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
        presenceCard.addView(presenceRow)
        addCard(content, presenceCard)

        val destinations = card()
        destinations.addView(sectionTitle("More", "ACTIVITY & SETTINGS"))
        destinations.addView(action("Encrypted history  ›").apply { setOnClickListener { history.performClick() } })
        destinations.addView(action("Encrypted chat  ›").apply { setOnClickListener { chat.performClick() } })
        destinations.addView(action("Contacts & safety numbers  ›").apply { setOnClickListener { safety.performClick() } })
        destinations.addView(action("Account, devices & privacy  ›").apply { setOnClickListener { showAccountSettings(active) } })
        addCard(content, destinations)
        setContentView(scroll(content))

        thread(name = "ptt-load-channels") {
            try {
                val available = ControlApi(active.serverUrl).channels(active)
                runOnUiThread {
                    progress.visibility = android.view.View.GONE
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
                        val preferred = available.firstOrNull {
                            it.channelId.equals(requestedChatChannelId, true)
                        } ?: available.first()
                        channelRows.getValue(preferred.channelId).performClick()
                        if (openChatRequested) {
                            openChatRequested = false
                            requestedChatChannelId = null
                            showChat(active, selectedChannel ?: preferred)
                        }
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    progress.visibility = android.view.View.GONE
                    connection.setTextColor(colorDanger())
                    connection.text = safeMessage(error)
                }
            }
        }
    }

    private fun showAccountSettings(active: DeviceSession) {
        val content = column()
        content.addView(sectionTitle("Settings"))
        content.addView(body("Your account, linked devices, encryption, and privacy choices."))

        val accountCard = card()
        accountCard.addView(sectionTitle("Account & devices", "SECURE IDENTITY"))
        accountCard.addView(statusPill("Account ${active.aci.take(8)}…  ·  Device ${active.deviceId} of 2"))
        val deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        accountCard.addView(deviceList)
        accountCard.addView(action("Link another device  ›").apply { setOnClickListener { showActiveDeviceLink(active) } })
        addCard(content, accountCard)

        val securityCard = card()
        securityCard.addView(sectionTitle("Encryption & privacy", "PROTECTED LOCALLY"))
        val status = statusPill("Loading secure device details…")
        securityCard.addView(status)
        val encryption = body("Loading device-key fingerprint…").apply {
            typeface = Typeface.MONOSPACE
            textSize = 13f
        }
        securityCard.addView(encryption)
        securityCard.addView(action(if (PttSessionService.isOverlayEnabled(this)) "Disable floating PTT" else "Enable floating PTT").apply {
            setOnClickListener {
                if (!PttSessionService.isArmed(this@TalkActivity)) {
                    status.text = "Tap Stay connected on the Talk screen before enabling floating PTT."
                } else if (PttSessionService.isOverlayEnabled(this@TalkActivity)) {
                    PttSessionService.setOverlay(this@TalkActivity, false)
                    text = "Enable floating PTT"
                } else if (!Settings.canDrawOverlays(this@TalkActivity)) {
                    status.text = "Allow Display over other apps, then return here and enable floating PTT."
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                } else {
                    PttSessionService.setOverlay(this@TalkActivity, true)
                    text = "Disable floating PTT"
                }
            }
        })
        securityCard.addView(action("Share privacy-redacted support report").apply {
            setOnClickListener { shareSupportReport(active) }
        })
        securityCard.addView(action("Open admin console").apply {
            setOnClickListener {
                runAction(this, status) {
                    val handoff = ControlApi(active.serverUrl).startAdminConsoleSession(active)
                    val destination = Uri.parse(handoff.adminUrl)
                    runOnUiThread { startActivity(Intent(Intent.ACTION_VIEW, destination)) }
                    "Admin console approved for 15 minutes."
                }
            }
        })
        securityCard.addView(action("Privacy policy and data choices  ›").apply {
            setOnClickListener { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL))) }
        })
        securityCard.addView(action("Remove this device").apply {
            setTextColor(colorDanger())
            setOnClickListener {
                AlertDialog.Builder(this@TalkActivity)
                    .setTitle("Remove this device?")
                    .setMessage("This revokes its server access and permanently deletes its local encryption keys.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Remove") { _, _ -> removeActiveDevice(active) }
                    .show()
            }
        })
        securityCard.addView(action("Delete account and server data").apply {
            setTextColor(colorDanger())
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
        addCard(content, securityCard)
        content.addView(action("Back to Talk").apply { setOnClickListener { showTalkHome(active) } })
        setContentView(scroll(content))

        thread(name = "ptt-load-settings") {
            try {
                val identityFingerprint =
                    EncryptedSignalProtocolStore.open(this).use {
                        fingerprint(it.identityKeyPair.publicKey.serialize())
                    }
                val accountDevices = ControlApi(active.serverUrl).devices(active)
                runOnUiThread {
                    status.text = "Encryption active on this device"
                    encryption.text =
                        "PQXDH + Double Ratchet authenticated Sender Keys · RFC 9605 SFrame\n" +
                            "Device key: $identityFingerprint"
                    accountDevices.forEach { device ->
                        val deviceRow = LinearLayout(this@TalkActivity).apply {
                            orientation = LinearLayout.VERTICAL
                            addView(body("Device ${device.deviceId} · ${device.displayName} · ${device.status}"))
                            if (device.status == "active" && device.deviceId != active.deviceId) {
                                addView(action("Revoke this linked device").apply {
                                    setTextColor(colorDanger())
                                    setOnClickListener {
                                        AlertDialog.Builder(this@TalkActivity)
                                            .setTitle("Revoke ${device.displayName}?")
                                            .setMessage("This removes the device and rotates affected channel keys.")
                                            .setNegativeButton("Cancel", null)
                                            .setPositiveButton("Revoke") { _, _ ->
                                                runAction(this, status) {
                                                    ControlApi(active.serverUrl).revokeDevice(active, device.deviceId)
                                                    runOnUiThread { showAccountSettings(active) }
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
                }
            } catch (error: Exception) {
                runOnUiThread {
                    status.setTextColor(colorDanger())
                    status.text = safeMessage(error)
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
                        status.setTextColor(colorDanger())
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
                        status.setTextColor(colorDanger())
                        status.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun showChat(active: DeviceSession, channel: ChannelSummary, initialStatus: String? = null) {
        val content = column()
        content.addView(title("Encrypted chat"))
        content.addView(body("${channel.displayName} · messages, files, voice notes, and video are end-to-end encrypted"))
        val preferences = runCatching {
            EncryptedChatClient(this, active).preferences(channel.channelId)
        }.getOrDefault(ChatConversationPreferences())
        if (preferences.isArchived) content.addView(statusPill("Archived on this device"))
        val preferenceRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun preferenceAction(label: String, update: (ChatConversationPreferences) -> ChatConversationPreferences) =
            action(label).apply {
                setOnClickListener {
                    val result = runCatching {
                        val client = EncryptedChatClient(this@TalkActivity, active)
                        client.savePreferences(channel.channelId, update(client.preferences(channel.channelId)))
                    }
                    showChat(active, channel, if (result.isSuccess) "Conversation preferences updated on this device." else safeMessage(result.exceptionOrNull()!!))
                }
            }
        preferenceRow.addView(preferenceAction(if (preferences.isMuted) "Unmute" else "Mute") {
            it.copy(isMuted = !it.isMuted)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        preferenceRow.addView(preferenceAction(if (preferences.isPinned) "Unpin" else "Pin chat") {
            it.copy(isPinned = !it.isPinned)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        preferenceRow.addView(preferenceAction(if (preferences.isArchived) "Restore" else "Archive") {
            it.copy(isArchived = !it.isArchived)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        content.addView(preferenceRow)
        content.addView(body("Retention: ${channel.retentionDays} days · membership epoch ${channel.membershipEpoch}"))
        content.addView(action("Participants and roles").apply {
            setOnClickListener {
                thread(name = "ptt-chat-participants") {
                    val result = runCatching {
                        ControlApi(active.serverUrl).channelDevices(active, channel.channelId)
                            .groupBy { it.aci.lowercase() }.map { (aci, devices) ->
                                val tag = java.security.MessageDigest.getInstance("SHA-256")
                                    .digest(aci.encodeToByteArray()).take(2)
                                    .joinToString("") { "%02X".format(it.toInt() and 0xff) }
                                val name = if (aci == active.aci.lowercase()) "You" else "Encrypted teammate $tag"
                                "$name · ${devices.size} device${if (devices.size == 1) "" else "s"} · ${devices.first().role}"
                            }.sorted().joinToString("\n")
                    }
                    runOnUiThread {
                        result.fold(
                            onSuccess = { members -> AlertDialog.Builder(this@TalkActivity)
                                .setTitle(channel.displayName)
                                .setMessage("Your role: ${channel.role}\nRetention: ${channel.retentionDays} days\n\n$members")
                                .setPositiveButton("Done", null).show() },
                            onFailure = { AlertDialog.Builder(this@TalkActivity)
                                .setTitle("Participants unavailable")
                                .setMessage(safeMessage(it)).setPositiveButton("Done", null).show() },
                        )
                    }
                }
            }
        })
        val rows = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        val status = statusPill(initialStatus ?: "Checking for new messages…")
        val search = EditText(this).apply {
            hint = "Search this conversation"
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
            setTextColor(colorText())
            setHintTextColor(colorMuted())
            background = rounded(colorSurfaceRaised(), 16f)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            contentDescription = "Search encrypted messages"
        }
        content.addView(search)
        content.addView(rows)
        content.addView(status)

        val composer = EditText(this).apply {
            hint = "Message"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minHeight = dp(54)
            maxLines = 5
            setTextColor(colorText())
            setHintTextColor(colorMuted())
            background = rounded(colorSurfaceRaised(), 16f)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            setText(
                runCatching { EncryptedChatClient(this@TalkActivity, active).draft(channel.channelId) }
                    .getOrDefault(""),
            )
        }
        composer.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                runCatching {
                    EncryptedChatClient(this@TalkActivity, active)
                        .saveDraft(channel.channelId, s?.toString().orEmpty())
                }
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        val composerContext = body("").apply { visibility = View.GONE }
        fun updateComposerContext() {
            val target = chatEditing ?: chatReplyTo
            if (target == null) {
                composerContext.visibility = View.GONE
            } else {
                composerContext.visibility = View.VISIBLE
                composerContext.text = if (chatEditing != null) "Editing message · tap to cancel" else "Replying to message · tap to cancel"
            }
        }
        composerContext.setOnClickListener {
            chatEditing = null
            chatReplyTo = null
            updateComposerContext()
        }
        updateComposerContext()
        content.addView(composerContext)
        content.addView(composer)
        content.addView(primaryAction("Send message").apply {
            setOnClickListener {
                val text = composer.text.toString().trim()
                if (text.isEmpty()) return@setOnClickListener
                isEnabled = false
                status.text = "Sending securely…"
                thread(name = "ptt-chat-text-send") {
                    val result = runCatching {
                        val client = EncryptedChatClient(this@TalkActivity, active)
                        chatEditing?.let { client.editMessage(text, it, channel) }
                            ?: client.sendText(text, channel, chatReplyTo)
                    }
                    runOnUiThread {
                        result.fold(
                            onSuccess = {
                                EncryptedChatClient(this@TalkActivity, active).saveDraft(channel.channelId, "")
                                chatEditing = null
                                chatReplyTo = null
                                showChat(active, channel, "Message sent securely.")
                            },
                            onFailure = {
                                val pending = runCatching { EncryptedChatClient(this@TalkActivity, active).pendingSendCount() }.getOrDefault(0)
                                if (pending > 0) {
                                    EncryptedChatClient(this@TalkActivity, active).saveDraft(channel.channelId, "")
                                    chatEditing = null
                                    chatReplyTo = null
                                    showChat(active, channel, "Message queued. It will send when the connection returns.")
                                } else {
                                    isEnabled = true
                                    status.text = safeMessage(it)
                                }
                            },
                        )
                    }
                }
            }
        })

        val attachmentRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun picker(label: String, kind: ChatContentKind, type: String) = action(label).apply {
            setOnClickListener {
                pendingChatChannel = channel
                pendingChatKind = kind
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    this.type = type
                }, REQUEST_CHAT_ATTACHMENT)
            }
        }
        attachmentRow.addView(picker("File", ChatContentKind.FILE, "*/*"), LinearLayout.LayoutParams(0, -2, 1f))
        attachmentRow.addView(picker("Video", ChatContentKind.VIDEO, "video/*"), LinearLayout.LayoutParams(0, -2, 1f))
        val voice = action(if (chatRecorder != null) "Stop" else if (chatPendingVoiceFile != null) "Send voice" else "Voice")
        voice.contentDescription = if (chatRecorder != null) "Stop voice message" else "Hold to record a voice message"
        voice.setOnClickListener {
            when {
                chatRecorder != null -> finishChatVoiceRecording(active, channel, status)
                chatPendingVoiceFile != null -> sendPendingChatVoice(active, channel)
                else -> startChatVoiceRecording(active, channel, status, voice)
            }
        }
        var voiceDownX = 0f
        var voiceDownY = 0f
        var recordingGesture = false
        var lockedAtTouchDown = false
        voice.setOnTouchListener { _, event ->
            if (chatPendingVoiceFile != null) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    voiceDownX = event.rawX
                    voiceDownY = event.rawY
                    lockedAtTouchDown = chatRecorderLocked
                    if (chatRecorder == null) startChatVoiceRecording(active, channel, status, voice)
                    recordingGesture = chatRecorder != null
                    if (recordingGesture && !lockedAtTouchDown) {
                        voice.text = "Slide ← cancel · ↑ lock"
                        status.text = "Recording… release to preview, slide left to cancel, or up to lock."
                    }
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (recordingGesture && !lockedAtTouchDown) {
                        val dx = event.rawX - voiceDownX
                        val dy = event.rawY - voiceDownY
                        when {
                            dx < -dp(80) -> { voice.text = "Release to cancel"; status.text = "Release to discard this recording." }
                            dy < -dp(70) -> { voice.text = "Release to lock"; status.text = "Release for hands-free recording." }
                            else -> { voice.text = "Slide ← cancel · ↑ lock"; status.text = "Recording voice message…" }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    when {
                        !recordingGesture -> Unit
                        lockedAtTouchDown -> finishChatVoiceRecording(active, channel, status)
                        event.rawX - voiceDownX < -dp(80) -> discardChatVoice(active, channel)
                        event.rawY - voiceDownY < -dp(70) -> {
                            chatRecorderLocked = true
                            showChat(active, channel, "Recording locked. Tap Stop when finished.")
                        }
                        else -> finishChatVoiceRecording(active, channel, status)
                    }
                    recordingGesture = false
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (recordingGesture && !lockedAtTouchDown) discardChatVoice(active, channel)
                    recordingGesture = false
                    true
                }
                else -> true
            }
        }
        attachmentRow.addView(voice, LinearLayout.LayoutParams(0, -2, 1f))
        content.addView(attachmentRow)
        if (chatRecorder != null) {
            val recorderControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            recorderControls.addView(action(if (chatRecorderPaused) "Resume recording" else "Pause recording").apply {
                setOnClickListener {
                    runCatching {
                        if (chatRecorderPaused) {
                            chatRecorder?.resume()
                            chatRecorderPausedTotal += System.currentTimeMillis() - chatRecorderPausedAt
                            chatRecorderPausedAt = 0
                        } else {
                            chatRecorder?.pause()
                            chatRecorderPausedAt = System.currentTimeMillis()
                        }
                        chatRecorderPaused = !chatRecorderPaused
                        showChat(active, channel, if (chatRecorderPaused) "Voice message paused." else "Recording voice message…")
                    }.onFailure { status.text = "Could not change the voice recorder state." }
                }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            recorderControls.addView(action("Discard recording").apply {
                setOnClickListener { discardChatVoice(active, channel) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            content.addView(recorderControls)
        } else if (chatPendingVoiceFile != null) {
            val pendingControls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            pendingControls.addView(action("Preview voice").apply {
                setOnClickListener { previewPendingChatVoice(status) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            pendingControls.addView(action("Discard voice").apply {
                setOnClickListener { discardChatVoice(active, channel) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            content.addView(pendingControls)
            content.addView(ChatVoiceWaveformView(this).apply {
                samples = chatPendingVoiceWaveform
                tintColor = colorAccent()
                isEnabled = false
            }, LinearLayout.LayoutParams(-1, dp(32)))
            content.addView(body("Voice message ready · ${chatPendingVoiceDurationMs / 1_000}s"))
        }
        content.addView(action("Refresh messages").apply { setOnClickListener { showChat(active, channel) } })
        content.addView(action("Back to Talk").apply { setOnClickListener { showTalkHome(active) } })
        val root = scroll(content)
        setContentView(root)

        var currentConversation: List<ChatConversationMessage> = emptyList()
        fun renderConversation() {
            val query = search.text.toString().trim()
            val visible = if (query.isEmpty()) currentConversation else currentConversation.filter {
                it.displayText.contains(query, ignoreCase = true) ||
                    (it.message.attachment?.fileName?.contains(query, ignoreCase = true) == true)
            }
            rows.removeAllViews()
            visible.forEach { item ->
                rows.addView(chatMessageView(active, channel, item, status, composer, composerContext))
            }
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = renderConversation()
            override fun afterTextChanged(s: Editable?) = Unit
        })

        lateinit var refresh: () -> Unit
        refresh = {
            if (!root.isAttachedToWindow) Unit else thread(name = "ptt-chat-refresh") {
                val result = runCatching {
                    val api = ControlApi(active.serverUrl)
                    val channels = api.channels(active)
                    val client = EncryptedChatClient(this, active)
                    client.poll(channels)
                    var conversation = client.conversation(channel.channelId)
                    conversation.filter { it.isUnread }.forEach {
                        runCatching { client.sendReceipt(ChatEventKind.READ, it.message.messageId, channel) }
                    }
                    if (conversation.any { it.isUnread }) conversation = client.conversation(channel.channelId)
                    conversation to client.pendingSendCount()
                }
                runOnUiThread {
                    if (!root.isAttachedToWindow) return@runOnUiThread
                    result.fold(
                        onSuccess = { (conversation, pending) ->
                            currentConversation = conversation
                            status.text = initialStatus ?: when {
                                pending > 0 -> "$pending message${if (pending == 1) "" else "s"} waiting for a connection."
                                conversation.isEmpty() -> "No messages yet. Start the conversation securely."
                                else -> "Messages are end-to-end encrypted."
                            }
                            renderConversation()
                        },
                        onFailure = { status.text = safeMessage(it) },
                    )
                    mainHandler.postDelayed({ refresh() }, 3_000)
                }
            }
        }
        refresh()
    }

    private fun chatMessageView(
        active: DeviceSession,
        channel: ChannelSummary,
        item: ChatConversationMessage,
        status: TextView,
        composer: EditText,
        composerContext: TextView,
    ): View {
        val message = item.message
        val mine = message.senderAci.equals(active.aci, ignoreCase = true)
        val bubble = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(if (mine) colorAccent() else colorSurfaceRaised(), 18f)
            setPadding(dp(13), dp(10), dp(13), dp(10))
        }
        if (item.replyToMessageId != null) bubble.addView(TextView(this).apply {
            text = "↩ Reply"
            textSize = 12f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (mine) 0xddffffff.toInt() else colorAccent())
        })
        val label = if (item.isDeleted) "Message deleted" else when (message.kind) {
            ChatContentKind.TEXT -> item.displayText
            ChatContentKind.VOICE -> "▶  ${message.attachment?.fileName ?: "Voice message"}"
            ChatContentKind.VIDEO -> "▶  ${message.attachment?.fileName ?: "Video"}"
            ChatContentKind.FILE -> "Open  ${message.attachment?.fileName ?: "File"}"
        }
        bubble.addView(TextView(this).apply {
            text = label
            textSize = 16f
            setTextColor(if (mine) Color.WHITE else colorText())
            if (item.isDeleted) setTypeface(typeface, Typeface.ITALIC)
        })
        if (!item.isDeleted && message.kind == ChatContentKind.VOICE) {
            val progress = ChatVoiceWaveformView(this).apply {
                samples = message.attachment?.waveform ?: byteArrayOf()
                tintColor = if (mine) Color.WHITE else colorAccent()
                progress = if (chatVoiceMessageId == message.messageId) {
                    val duration = chatVoicePlayer?.duration?.coerceAtLeast(1) ?: 1
                    ((chatVoicePlayer?.currentPosition ?: 0).toFloat() / duration).coerceIn(0f, 1f)
                } else 0f
                onSeek = { value ->
                    if (chatVoiceMessageId == message.messageId) {
                        chatVoicePlayer?.duration?.let { duration ->
                            chatVoicePlayer?.seekTo((duration * value).toInt())
                        }
                    }
                }
            }
            bubble.addView(progress, LinearLayout.LayoutParams(-1, dp(32)))
            bubble.addView(action("${chatVoicePlaybackRate}× playback").apply {
                setOnClickListener {
                    chatVoicePlaybackRate = when (chatVoicePlaybackRate) { 1f -> 1.5f; 1.5f -> 2f; else -> 1f }
                    chatVoicePlayer?.let { player ->
                        player.playbackParams = player.playbackParams.setSpeed(chatVoicePlaybackRate)
                    }
                    text = "${chatVoicePlaybackRate}× playback"
                }
            })
            val update = object : Runnable {
                override fun run() {
                    if (!progress.isAttachedToWindow || chatVoiceMessageId != message.messageId) return
                    val duration = chatVoicePlayer?.duration?.coerceAtLeast(1) ?: return
                    progress.progress = ((chatVoicePlayer?.currentPosition ?: 0).toFloat() / duration).coerceIn(0f, 1f)
                    mainHandler.postDelayed(this, 100)
                }
            }
            mainHandler.post(update)
        }
        if (item.reactions.isNotEmpty()) bubble.addView(TextView(this).apply {
            text = item.reactions.values.sorted().joinToString(" ")
            textSize = 13f
            setTextColor(if (mine) Color.WHITE else colorText())
        })
        if (item.isPinned || item.isStarred) bubble.addView(TextView(this).apply {
            text = buildList {
                if (item.isPinned) add("📌 Pinned")
                if (item.isStarred) add("★ Starred")
            }.joinToString("  ")
            textSize = 11f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (mine) 0xddffffff.toInt() else colorAccent())
        })
        bubble.addView(TextView(this).apply {
            val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
                .format(java.util.Date(message.sentAt.toEpochMilli()))
            val edited = if (item.editedText != null) "Edited · " else ""
            val delivery = item.sendState?.let {
                when (it) {
                    ChatSendState.QUEUED -> " · Queued"
                    ChatSendState.SENDING -> " · Sending"
                    ChatSendState.FAILED -> " · Failed"
                    ChatSendState.SENT -> " · ✓"
                    ChatSendState.DELIVERED -> " · Delivered"
                    ChatSendState.READ -> " · Read"
                    ChatSendState.PLAYED -> " · Played"
                }
            }.orEmpty()
            text = "$edited$time${if (mine) delivery else ""}"
            textSize = 11f
            gravity = Gravity.END
            setTextColor(if (mine) 0xccffffff.toInt() else colorMuted())
        })
        if (!item.isDeleted && message.kind == ChatContentKind.VOICE) bubble.setOnClickListener {
            toggleChatVoicePlayback(active, channel, item, status)
        } else if (!item.isDeleted && message.attachment != null) bubble.setOnClickListener {
            status.text = "Downloading and verifying attachment…"
            thread(name = "ptt-chat-attachment-open") {
                val result = runCatching {
                    val bytes = EncryptedChatClient(this, active).attachmentData(message)
                    val file = ChatAttachmentProvider.write(this, message.messageId.toString(), message.attachment.fileName, bytes)
                    val uri = ChatAttachmentProvider.uri(this, file)
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, message.attachment.mimeType)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
                runOnUiThread {
                    result.fold(
                        onSuccess = { intent -> startActivity(intent) },
                        onFailure = { status.text = safeMessage(it) },
                    )
                }
            }
        }
        if (!item.isDeleted) bubble.setOnLongClickListener {
            val choices = buildList {
                add("Reply")
                add("Copy")
                add("Share")
                add("Forward")
                add("React")
                add(if (item.isPinned) "Unpin" else "Pin")
                add(if (item.isStarred) "Unstar" else "Star")
                add("Info")
                if (mine && message.kind == ChatContentKind.TEXT) add("Edit")
                if (mine) add("Delete")
            }
            AlertDialog.Builder(this).setTitle("Message actions").setItems(choices.toTypedArray()) { _, which ->
                when (choices[which]) {
                    "Reply" -> {
                        chatEditing = null
                        chatReplyTo = message.messageId
                        composerContext.text = "Replying to message · tap to cancel"
                        composerContext.visibility = View.VISIBLE
                        composer.requestFocus()
                    }
                    "Edit" -> {
                        chatReplyTo = null
                        chatEditing = message.messageId
                        composer.setText(item.displayText)
                        composer.setSelection(composer.text.length)
                        composerContext.text = "Editing message · tap to cancel"
                        composerContext.visibility = View.VISIBLE
                        composer.requestFocus()
                    }
                    "Copy" -> {
                        val value = item.displayText.ifBlank { message.attachment?.fileName.orEmpty() }
                        getSystemService(ClipboardManager::class.java)
                            .setPrimaryClip(ClipData.newPlainText("PTT Talk message", value))
                        status.text = "Copied on this device."
                    }
                    "Share" -> shareChatMessage(active, item, status)
                    "Forward" -> forwardChatMessage(active, item, status)
                    "Pin", "Unpin" -> thread(name = "ptt-chat-pin") {
                        val result = runCatching {
                            EncryptedChatClient(this, active).setPinned(!item.isPinned, message.messageId, channel)
                        }
                        runOnUiThread {
                            showChat(active, channel, if (result.isSuccess) {
                                if (item.isPinned) "Message unpinned." else "Message pinned."
                            } else safeMessage(result.exceptionOrNull()!!))
                        }
                    }
                    "Star", "Unstar" -> {
                        val result = runCatching {
                            EncryptedChatClient(this, active).setStarred(
                                channel.channelId, message.messageId, !item.isStarred,
                            )
                        }
                        showChat(active, channel, if (result.isSuccess) {
                            if (item.isStarred) "Message unstarred on this device." else "Message starred on this device."
                        } else safeMessage(result.exceptionOrNull()!!))
                    }
                    "Info" -> AlertDialog.Builder(this)
                        .setTitle("Message information")
                        .setMessage(chatMessageInformation(active, item))
                        .setPositiveButton("Done", null)
                        .show()
                    "Delete" -> thread(name = "ptt-chat-delete") {
                        val result = runCatching { EncryptedChatClient(this, active).deleteMessage(message.messageId, channel) }
                        runOnUiThread { showChat(active, channel, if (result.isSuccess) "Message deleted." else safeMessage(result.exceptionOrNull()!!)) }
                    }
                    "React" -> {
                        val reactions = arrayOf("👍", "❤️", "😂", "‼️")
                        AlertDialog.Builder(this).setTitle("React").setItems(reactions) { _, reactionIndex ->
                            thread(name = "ptt-chat-reaction") {
                                val client = EncryptedChatClient(this, active)
                                val mineReaction = item.reactions[active.aci.lowercase()]
                                val result = runCatching {
                                    if (mineReaction == reactions[reactionIndex]) client.removeReaction(message.messageId, channel)
                                    else client.sendReaction(reactions[reactionIndex], message.messageId, channel)
                                }
                                runOnUiThread { showChat(active, channel, if (result.isSuccess) "Reaction updated." else safeMessage(result.exceptionOrNull()!!)) }
                            }
                        }.show()
                    }
                }
            }.show()
            true
        }
        return LinearLayout(this).apply {
            gravity = if (mine) Gravity.END else Gravity.START
            setPadding(if (mine) dp(48) else 0, dp(4), if (mine) 0 else dp(48), dp(4))
            addView(bubble, LinearLayout.LayoutParams(-2, -2))
        }
    }

    private fun shareChatMessage(active: DeviceSession, item: ChatConversationMessage, status: TextView) {
        val message = item.message
        if (message.attachment == null) {
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, item.displayText)
            }, "Share message"))
            return
        }
        status.text = "Downloading and verifying attachment for sharing…"
        thread(name = "ptt-chat-share") {
            val result = runCatching {
                val bytes = EncryptedChatClient(this, active).attachmentData(message)
                val file = ChatAttachmentProvider.write(
                    this, "share-${message.messageId}", message.attachment.fileName, bytes,
                )
                val uri = ChatAttachmentProvider.uri(this, file)
                Intent(Intent.ACTION_SEND).apply {
                    type = message.attachment.mimeType
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            runOnUiThread {
                result.fold(
                    onSuccess = { startActivity(Intent.createChooser(it, "Share attachment")) },
                    onFailure = { status.text = safeMessage(it) },
                )
            }
        }
    }

    private fun forwardChatMessage(active: DeviceSession, item: ChatConversationMessage, status: TextView) {
        status.text = "Loading secure destinations…"
        thread(name = "ptt-chat-forward-destinations") {
            val channels = runCatching { ControlApi(active.serverUrl).channels(active) }
            runOnUiThread {
                channels.fold(
                    onSuccess = { destinations ->
                        AlertDialog.Builder(this).setTitle("Forward securely to")
                            .setItems(destinations.map { it.displayName }.toTypedArray()) { _, index ->
                                val destination = destinations[index]
                                status.text = "Forwarding securely to ${destination.displayName}…"
                                thread(name = "ptt-chat-forward") {
                                    val result = runCatching {
                                        val client = EncryptedChatClient(this, active)
                                        val attachment = item.message.attachment
                                        if (attachment == null) {
                                            client.sendText(item.displayText, destination)
                                        } else {
                                            client.sendAttachment(
                                                client.attachmentData(item.message),
                                                attachment.fileName,
                                                attachment.mimeType,
                                                item.message.kind,
                                                durationMs = attachment.durationMs,
                                                waveform = attachment.waveform,
                                                caption = item.displayText,
                                                channel = destination,
                                            )
                                        }
                                    }
                                    runOnUiThread {
                                        status.text = if (result.isSuccess) {
                                            "Forwarded with new end-to-end encryption."
                                        } else safeMessage(result.exceptionOrNull()!!)
                                    }
                                }
                            }.setNegativeButton("Cancel", null).show()
                    },
                    onFailure = { status.text = safeMessage(it) },
                )
            }
        }
    }

    private fun chatMessageInformation(active: DeviceSession, item: ChatConversationMessage): String {
        val message = item.message
        val sender = if (message.senderAci.equals(active.aci, true)) {
            "You · device ${message.senderDeviceId}"
        } else "Encrypted teammate · device ${message.senderDeviceId}"
        val state = item.sendState?.name?.lowercase()?.replaceFirstChar(Char::uppercase) ?: "Received"
        val attachment = message.attachment?.let {
            "\nAttachment: ${it.fileName} · ${android.text.format.Formatter.formatShortFileSize(this, it.plaintextBytes)}"
        }.orEmpty()
        return "$sender\n${java.text.DateFormat.getDateTimeInstance().format(java.util.Date(message.sentAt.toEpochMilli()))}" +
            "\n$state\nMembership epoch ${message.membershipEpoch}\nMessage ID ${message.messageId}$attachment"
    }

    private fun startChatVoiceRecording(active: DeviceSession, channel: ChannelSummary, status: TextView, button: Button) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            status.text = "Allow microphone access from the Talk screen first."
            return
        }
        runCatching {
            chatPendingVoiceFile?.delete()
            chatPendingVoiceFile = null
            chatPendingVoiceDurationMs = 0
            chatPendingVoiceWaveform = byteArrayOf()
            val file = java.io.File(cacheDir, "voice-${UUID.randomUUID()}.m4a")
            val recorder = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioSamplingRate(24_000)
            recorder.setAudioEncodingBitRate(48_000)
            recorder.setOutputFile(file.absolutePath)
            recorder.setMaxDuration(300_000)
            recorder.prepare()
            recorder.start()
            chatRecorder = recorder
            chatRecorderFile = file
            chatRecorderStartedAt = System.currentTimeMillis()
            chatRecorderPaused = false
            chatRecorderLocked = false
            chatRecorderPausedAt = 0
            chatRecorderPausedTotal = 0
            chatRecorderSamples.clear()
            val meter = object : Runnable {
                override fun run() {
                    val activeRecorder = chatRecorder ?: return
                    val amplitude = runCatching { activeRecorder.maxAmplitude }.getOrDefault(0)
                    val normalized = kotlin.math.sqrt(amplitude.coerceIn(0, 32_767) / 32_767f)
                    if (chatRecorderSamples.size < 6_000) {
                        chatRecorderSamples += (normalized * 255).toInt().coerceIn(0, 255).toByte()
                    }
                    mainHandler.postDelayed(this, 50)
                }
            }
            chatRecorderMeterTask = meter
            mainHandler.post(meter)
            button.text = "Stop"
            status.text = "Recording voice message…"
        }.onFailure { status.text = "Could not start the voice recorder." }
    }

    private fun finishChatVoiceRecording(active: DeviceSession, channel: ChannelSummary, status: TextView) {
        val recorder = chatRecorder ?: return
        val file = chatRecorderFile ?: return
        val now = System.currentTimeMillis()
        val activePause = if (chatRecorderPaused) now - chatRecorderPausedAt else 0
        val duration = (now - chatRecorderStartedAt - chatRecorderPausedTotal - activePause).toInt().coerceIn(0, 300_000)
        chatRecorderMeterTask?.let(mainHandler::removeCallbacks)
        chatRecorderMeterTask = null
        runCatching { recorder.stop() }
        recorder.release()
        chatRecorder = null
        chatRecorderFile = null
        chatRecorderPaused = false
        chatRecorderLocked = false
        chatRecorderPausedAt = 0
        chatRecorderPausedTotal = 0
        val waveform = normalizedVoiceWaveform(chatRecorderSamples)
        chatRecorderSamples.clear()
        if (duration < 300) {
            chatPendingVoiceWaveform = byteArrayOf()
            file.delete()
            showChat(active, channel, "Voice message was too short.")
            return
        }
        chatPendingVoiceFile = file
        chatPendingVoiceDurationMs = duration
        chatPendingVoiceWaveform = waveform
        showChat(active, channel, "Voice message ready. Preview, send, or discard it.")
    }

    private fun sendPendingChatVoice(active: DeviceSession, channel: ChannelSummary) {
        val file = chatPendingVoiceFile ?: return
        val duration = chatPendingVoiceDurationMs
        val waveform = chatPendingVoiceWaveform.copyOf()
        chatPendingVoiceFile = null
        chatPendingVoiceDurationMs = 0
        chatPendingVoiceWaveform = byteArrayOf()
        thread(name = "ptt-chat-voice-send") {
            val result = runCatching {
                EncryptedChatClient(this, active).sendAttachment(
                    file.readBytes(), "Voice message.m4a", "audio/mp4", ChatContentKind.VOICE,
                    durationMs = duration, waveform = waveform, channel = channel,
                )
            }
            file.delete()
            runOnUiThread {
                result.fold(
                    onSuccess = { showChat(active, channel, "Voice message sent securely.") },
                    onFailure = {
                        val queued = runCatching { EncryptedChatClient(this, active).pendingSendCount() }.getOrDefault(0) > 0
                        showChat(active, channel, if (queued) "Voice message queued. It will send when connected." else safeMessage(it))
                    },
                )
            }
        }
    }

    private fun discardChatVoice(active: DeviceSession, channel: ChannelSummary) {
        runCatching { chatRecorder?.stop() }
        runCatching { chatRecorder?.release() }
        chatRecorderMeterTask?.let(mainHandler::removeCallbacks)
        chatRecorderMeterTask = null
        chatRecorderSamples.clear()
        chatRecorder = null
        chatRecorderPaused = false
        chatRecorderLocked = false
        chatRecorderPausedAt = 0
        chatRecorderPausedTotal = 0
        chatRecorderFile?.delete()
        chatRecorderFile = null
        chatPendingVoiceFile?.delete()
        chatPendingVoiceFile = null
        chatPendingVoiceDurationMs = 0
        chatPendingVoiceWaveform = byteArrayOf()
        showChat(active, channel, "Voice message discarded.")
    }

    private fun normalizedVoiceWaveform(samples: List<Byte>, count: Int = 48): ByteArray {
        if (samples.isEmpty()) return byteArrayOf()
        val bins = minOf(count, samples.size)
        return ByteArray(bins) { index ->
            val lower = index * samples.size / bins
            val upper = maxOf(lower + 1, (index + 1) * samples.size / bins).coerceAtMost(samples.size)
            var maximum = 0
            for (sampleIndex in lower until upper) maximum = maxOf(maximum, samples[sampleIndex].toInt() and 0xff)
            maximum.toByte()
        }
    }

    private fun previewPendingChatVoice(status: TextView) {
        val file = chatPendingVoiceFile ?: return
        runCatching {
            val bytes = file.readBytes()
            val shared = ChatAttachmentProvider.write(this, "voice-preview", "Voice message.m4a", bytes)
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(ChatAttachmentProvider.uri(this@TalkActivity, shared), "audio/mp4")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
        }.onFailure { status.text = "Could not preview the voice message." }
    }

    private fun toggleChatVoicePlayback(
        active: DeviceSession,
        channel: ChannelSummary,
        item: ChatConversationMessage,
        status: TextView,
    ) {
        val message = item.message
        if (chatVoiceMessageId == message.messageId) {
            chatVoicePlayer?.let { player ->
                if (player.isPlaying) {
                    player.pause()
                    status.text = "Voice message paused."
                } else {
                    player.start()
                    status.text = "Playing voice message at ${chatVoicePlaybackRate}×."
                }
            }
            return
        }
        status.text = "Downloading and verifying voice message…"
        thread(name = "ptt-chat-voice-play") {
            val result = runCatching {
                stopChatVoicePlayback()
                val bytes = EncryptedChatClient(this, active).attachmentData(message)
                val file = java.io.File(cacheDir, "voice-play-${message.messageId}.m4a")
                file.writeBytes(bytes)
                val player = MediaPlayer().apply {
                    setDataSource(file.absolutePath)
                    prepare()
                    playbackParams = playbackParams.setSpeed(chatVoicePlaybackRate)
                    setOnCompletionListener {
                        thread(name = "ptt-chat-played-receipt") {
                            val client = EncryptedChatClient(this@TalkActivity, active)
                            if (!message.senderAci.equals(active.aci, true)) {
                                runCatching {
                                    client.sendReceipt(ChatEventKind.PLAYED, message.messageId, channel)
                                }
                            }
                            val conversation = runCatching { client.conversation(channel.channelId) }.getOrDefault(emptyList())
                            val index = conversation.indexOfFirst { it.message.messageId == message.messageId }
                            val nextVoice = if (index >= 0) conversation.getOrNull(index + 1)?.takeIf {
                                !it.isDeleted && it.message.kind == ChatContentKind.VOICE
                            } else null
                            runOnUiThread {
                                stopChatVoicePlayback()
                                if (nextVoice != null) {
                                    toggleChatVoicePlayback(active, channel, nextVoice, status)
                                } else {
                                    showChat(active, channel, "Voice message played.")
                                }
                            }
                        }
                    }
                    start()
                }
                chatVoicePlaybackFile = file
                chatVoicePlayer = player
                chatVoiceMessageId = message.messageId
            }
            runOnUiThread {
                status.text = if (result.isSuccess) "Playing voice message at ${chatVoicePlaybackRate}×."
                else "Could not download or verify this voice message."
            }
        }
    }

    @Synchronized
    private fun stopChatVoicePlayback() {
        runCatching { chatVoicePlayer?.stop() }
        runCatching { chatVoicePlayer?.release() }
        chatVoicePlayer = null
        chatVoiceMessageId = null
        chatVoicePlaybackFile?.delete()
        chatVoicePlaybackFile = null
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
        content.addView(title("Add another device"))
        content.addView(body("Create one private setup link, send it to the new device with AirDrop or Messages, then approve it here."))
        val details = body("")
        val manual = body("").apply { visibility = View.GONE }
        val start = primaryAction("Create setup link")
        val share = primaryAction("Send setup link").apply { isEnabled = false }
        val showCodes = action("Show manual fallback codes  ›").apply { visibility = View.GONE }
        val approve = primaryAction("Approve new device").apply { isEnabled = false }
        val status = body("")
        content.addView(start)
        content.addView(details)
        content.addView(share)
        content.addView(showCodes)
        content.addView(manual)
        content.addView(approve)
        content.addView(status)
        content.addView(action("Back").apply { setOnClickListener { showTalkHome(active) } })
        var pendingRequestId: String? = null
        var pendingInviteUrl: String? = null
        start.setOnClickListener {
            runAction(start, status) {
                val link = ControlApi(active.serverUrl).startDeviceLink(active)
                pendingRequestId = link.requestId
                pendingInviteUrl = requireNotNull(deviceLinkInviteUrl(active.serverUrl, link.requestId, link.linkCode))
                runOnUiThread {
                    details.text = "The link expires in 10 minutes and works once. After it opens on the new device, return here for the final approval."
                    manual.text = "Request ID\n${link.requestId}\n\nOne-time code\n${link.linkCode}"
                    share.isEnabled = true
                    showCodes.visibility = View.VISIBLE
                    approve.isEnabled = true
                }
                "Setup link ready."
            }
        }
        share.setOnClickListener {
            val url = pendingInviteUrl ?: return@setOnClickListener
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, "Add a device to PTT Talk")
                putExtra(Intent.EXTRA_TEXT, "Open this one-time setup link on the device you want to add to PTT Talk:\n\n$url")
            }
            startActivity(Intent.createChooser(send, "Send setup link"))
        }
        showCodes.setOnClickListener {
            manual.visibility = if (manual.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            showCodes.text = if (manual.visibility == View.VISIBLE) "Hide manual fallback codes" else "Show manual fallback codes  ›"
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
            setTextColor(colorText())
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = rounded(colorSurfaceRaised(), 14f, colorBorder(), 1)
            layoutParams = spacedParams(vertical = 4)
            isFocusable = true
            contentDescription = "${channel.displayName}, ${channel.role}, ${channel.kind}, key epoch ${channel.membershipEpoch}"
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
        status.setTextColor(colorMuted())
        status.text = "Preparing ${channel.displayName} securely…"
        (row.parent as? LinearLayout)?.let { parent ->
            repeat(parent.childCount) { index ->
                parent.getChildAt(index).background =
                    if (parent.getChildAt(index) === row) {
                        rounded(withAlpha(colorAccent(), if (isDarkTheme()) 44 else 28), 14f, colorAccent(), 2)
                    } else {
                        rounded(colorSurfaceRaised(), 14f, colorBorder(), 1)
                    }
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
        stopChatVoicePlayback()
        talkPressed = true
        button.text = "Requesting floor…"
        status.text = "Waiting for an authenticated floor grant…"
        PttSessionService.beginTransmit(this, channel)
    }

    private fun endTalk(button: Button, status: TextView) {
        if (!talkPressed) return
        talkPressed = false
        button.text = "Hold to talk"
        status.setTextColor(colorMuted())
        status.text = "Releasing floor…"
        tones.released()
        PttSessionService.endTransmit(this)
    }

    private fun runAction(button: Button, status: TextView, operation: () -> String) {
        button.isEnabled = false
        status.setTextColor(colorMuted())
        status.text = "Working securely…"
        thread(name = "ptt-account-action") {
            val result = runCatching(operation)
            runOnUiThread {
                button.isEnabled = true
                status.setTextColor(if (result.isSuccess) colorSuccess() else colorDanger())
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
                        status.setTextColor(colorDanger())
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
                        status.setTextColor(colorDanger())
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
            setPadding(dp(18), dp(20), dp(18), dp(40))
            setBackgroundColor(colorBackground())
        }

    private fun scroll(content: LinearLayout): ScrollView = ScrollView(this).apply {
        isFillViewport = true
        clipToPadding = true
        overScrollMode = View.OVER_SCROLL_NEVER
        setBackgroundColor(colorBackground())
        setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            }
            insets
        }
        addView(content)
    }

    private fun title(value: String, size: Float = 28f): TextView = TextView(this).apply {
        text = value
        textSize = size
        typeface = Typeface.create("sans-serif", Typeface.BOLD)
        letterSpacing = if (size >= 26f) -0.02f else 0f
        setTextColor(colorText())
        setPadding(0, dp(8), 0, dp(if (size >= 26f) 10 else 6))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
    }

    private fun body(value: String): TextView = TextView(this).apply {
        text = value
        textSize = 15f
        setTextColor(colorMuted())
        setLineSpacing(0f, 1.12f)
        setPadding(0, dp(6), 0, dp(8))
    }

    private fun brandMark(): ImageView = ImageView(this).apply {
        setImageResource(R.mipmap.ic_launcher)
        contentDescription = "PTT Talk"
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        layoutParams = LinearLayout.LayoutParams(dp(86), dp(86)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            setMargins(0, dp(10), 0, dp(10))
        }
    }

    private fun stepRow(number: Int, heading: String, detail: String): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(0, dp(6), 0, dp(6))
            addView(TextView(this@TalkActivity).apply {
                text = number.toString()
                gravity = Gravity.CENTER
                textSize = 13f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(if (isDarkTheme()) Color.rgb(2, 23, 42) else Color.WHITE)
                background = rounded(colorAccent(), 50f)
            }, LinearLayout.LayoutParams(dp(28), dp(28)).apply { setMargins(0, 0, dp(12), 0) })
            addView(LinearLayout(this@TalkActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(TextView(this@TalkActivity).apply {
                    text = heading
                    textSize = 15f
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                    setTextColor(colorText())
                })
                addView(TextView(this@TalkActivity).apply {
                    text = detail
                    textSize = 13f
                    setTextColor(colorMuted())
                    setPadding(0, dp(2), 0, 0)
                })
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }

    private fun field(hint: String, value: String = "", secret: Boolean = false): EditText = EditText(this).apply {
        this.hint = hint
        setText(value)
        if (secret) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        setSingleLine(true)
        textSize = 16f
        setTextColor(colorText())
        setHintTextColor(colorMuted())
        background = rounded(colorSurface(), 14f, colorBorder(), 1)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        layoutParams = spacedParams(vertical = 5)
    }

    private fun action(label: String): Button = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 15f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(colorAccent())
        background = rounded(colorSurfaceRaised(), 14f, colorBorder(), 1)
        minHeight = dp(52)
        stateListAnimator = null
        elevation = 0f
        setPadding(dp(14), dp(12), dp(14), dp(12))
        layoutParams = spacedParams(vertical = 5)
    }

    private fun primaryAction(label: String): Button = action(label).apply {
        setTextColor(if (isDarkTheme()) Color.rgb(2, 23, 42) else Color.WHITE)
        background = rounded(colorAccent(), 16f)
        elevation = dp(2).toFloat()
    }

    private fun dangerAction(label: String): Button = action(label).apply {
        setTextColor(Color.WHITE)
        background = rounded(colorDanger(), 14f)
    }

    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        background = rounded(colorSurface(), 22f, colorBorder(), 1)
        elevation = if (isDarkTheme()) 0f else dp(2).toFloat()
        clipToOutline = true
    }

    private fun addCard(parent: LinearLayout, child: LinearLayout) {
        parent.addView(
            child,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                setMargins(0, dp(7), 0, dp(7))
            },
        )
    }

    private fun sectionTitle(value: String, eyebrow: String? = null): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        if (eyebrow != null) {
            addView(TextView(this@TalkActivity).apply {
                text = eyebrow
                textSize = 12f
                letterSpacing = 0.02f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setTextColor(colorMuted())
            })
        }
        addView(title(value, 20f))
    }

    private fun statusPill(value: String): TextView = body(value).apply {
        textSize = 13f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(colorSuccess())
        background = rounded(withAlpha(colorSuccess(), 26), 50f, withAlpha(colorSuccess(), 70), 1)
        setPadding(dp(12), dp(8), dp(12), dp(8))
    }

    private fun spacedParams(vertical: Int): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            setMargins(0, dp(vertical), 0, dp(vertical))
        }

    private fun rounded(fill: Int, radiusDp: Float, stroke: Int? = null, strokeDp: Int = 0): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(radiusDp.toInt()).toFloat()
            setColor(fill)
            if (stroke != null && strokeDp > 0) setStroke(dp(strokeDp), stroke)
        }

    private fun isDarkTheme(): Boolean =
        resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun colorBackground(): Int = Color.parseColor(if (isDarkTheme()) "#061125" else "#F4F7FB")
    private fun colorSurface(): Int = Color.parseColor(if (isDarkTheme()) "#0D1D36" else "#FFFFFF")
    private fun colorSurfaceRaised(): Int = Color.parseColor(if (isDarkTheme()) "#142944" else "#EAF1F8")
    private fun colorBorder(): Int = Color.parseColor(if (isDarkTheme()) "#27415E" else "#D9E4EF")
    private fun colorText(): Int = Color.parseColor(if (isDarkTheme()) "#F4FAFF" else "#10233F")
    private fun colorMuted(): Int = Color.parseColor(if (isDarkTheme()) "#A4B7CC" else "#58708A")
    private fun colorAccent(): Int = Color.parseColor(if (isDarkTheme()) "#18D8EF" else "#007FA8")
    private fun colorSuccess(): Int = Color.parseColor(if (isDarkTheme()) "#39D7B5" else "#087C69")
    private fun colorDanger(): Int = Color.parseColor(if (isDarkTheme()) "#FF496A" else "#C62948")

    private fun withAlpha(color: Int, alpha: Int): Int = Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))

    private fun defaultServer(): String =
        configuredServer
            ?: intent.getStringExtra("ptt_server")
            ?: if (BuildConfig.DEBUG) "http://10.0.2.2:8080" else "https://ptttalk.app"

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
        const val REQUEST_CHAT_ATTACHMENT = 4103
        const val PRIVACY_POLICY_URL = "https://ptttalk.app/privacy#deletion"
    }
}
