package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.Manifest
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
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
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
                        talkStatusView?.setTextColor(colorSuccess())
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_GRANTED -> {
                        talkButton?.isEnabled = true
                        talkButton?.text = "Floor granted — talking"
                        talkStatusView?.setTextColor(colorSuccess())
                        if (!detail.startsWith("Silent SOS")) tones.granted()
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
        window.statusBarColor = colorBackground()
        window.navigationBarColor = colorBackground()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            window.decorView.systemUiVisibility =
                if (isDarkTheme()) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
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
                )
            credentials.save(enrolled)
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
                    )
                }
                runOnUiThread {
                    result.fold(
                        onSuccess = { enrolled ->
                            credentials.save(enrolled)
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
        content.addView(body("On your current device, open Settings → Link another device. Enter the request ID and one-time code shown there."))
        val server = field("Server URL", defaultServer())
        val requestId = field("Link request ID")
        val linkCode = field("One-time link code", secret = true)
        content.addView(server)
        content.addView(requestId)
        content.addView(linkCode)
        val claim = primaryAction("Ask my other device to approve")
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

    private fun showPendingDeviceLink(pending: PendingDeviceLink) {
        val screen = ++recoveryScreen
        val content = column()
        content.addView(title("Device approval pending"))
        content.addView(body("Return to the active device and approve request ${pending.requestId.take(8)}…."))
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
                        (channels.getChildAt(0) as TextView).performClick()
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
        val start = primaryAction("Generate link code")
        val approve = primaryAction("Approve claimed device").apply { isEnabled = false }
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
