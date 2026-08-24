package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.graphics.Color
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
    private var relayCredential: RelayCredential? = null
    private var heldFloorToken: String? = null
    private var talkPressed = false
    private var floorGeneration = 0
    private var channelGeneration = 0
    private var armButton: Button? = null

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
        floorGeneration++
        channelGeneration++
        selectedChannel = null
        relayCredential = null
        heldFloorToken = null
        talkPressed = false
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
                    } else {
                        requestSessionPermissionsOrArm()
                    }
                }
            }
        content.addView(requireNotNull(armButton))
        content.addView(body("Background receive is active only after you tap Stay connected; reboot requires another tap."))
        content.addView(title("Devices", 20f))
        val deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(deviceList)
        content.addView(action("Link another device").apply { setOnClickListener { showActiveDeviceLink(active) } })
        val connection = body("Connecting securely…")
        content.addView(connection)
        content.addView(title("Channels", 20f))
        val channels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(channels)
        val talkStatus = body("Select a channel to prepare its authenticated floor and relay session.")
        val talk = action("Hold to talk").apply {
            isEnabled = false
            minHeight = dp(88)
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        beginTalk(active, this, talkStatus)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        endTalk(active, this, talkStatus)
                        true
                    }
                    else -> false
                }
            }
        }
        content.addView(talk)
        content.addView(talkStatus)
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
                        "Encryption: PQXDH + Double Ratchet + Sender Keys · RFC 9605 SFrame\n" +
                            "This device key: $identityFingerprint"
                    accountDevices.forEach { device ->
                        deviceList.addView(body("Device ${device.deviceId} · ${device.displayName} · ${device.status}"))
                    }
                    if (available.isEmpty()) {
                        connection.text = "Secure account connection ready"
                        channels.addView(body("No channels yet. Ask an administrator to add you."))
                    } else {
                        available.forEach { channel ->
                            val row = channelRow(channel)
                            row.setOnClickListener {
                                selectChannel(active, channel, row, talk, talkStatus)
                            }
                            channels.addView(row)
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

    private fun showActiveDeviceLink(active: DeviceSession) {
        floorGeneration++
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
        val generation = ++channelGeneration
        selectedChannel = channel
        relayCredential = null
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
        thread(name = "ptt-relay-credential") {
            val result = runCatching { ControlApi(active.serverUrl).relayCredential(active, channel.channelId) }
            runOnUiThread {
                if (generation != channelGeneration || session != active) return@runOnUiThread
                result.fold(
                    onSuccess = {
                        relayCredential = it
                        talk.isEnabled = channel.role != "listen"
                        status.setTextColor(Color.rgb(8, 117, 92))
                        status.text =
                            if (channel.role == "listen") "Listening to ${channel.displayName}; your role cannot transmit."
                            else "${channel.displayName} is ready. Hold the button to request the floor."
                    },
                    onFailure = {
                        status.setTextColor(Color.rgb(150, 40, 40))
                        status.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun beginTalk(active: DeviceSession, button: Button, status: TextView) {
        val channel = selectedChannel ?: return
        val relay = relayCredential ?: return
        if (talkPressed || heldFloorToken != null) return
        talkPressed = true
        val generation = ++floorGeneration
        button.text = "Requesting floor…"
        status.text = "Waiting for an authenticated floor grant…"
        thread(name = "ptt-floor-request") {
            val result = runCatching { ControlApi(active.serverUrl).requestFloor(active, channel, relay) }
            runOnUiThread {
                result.fold(
                    onSuccess = { grant ->
                        if (!grant.granted) {
                            if (generation == floorGeneration) {
                                talkPressed = false
                                button.text = "Hold to talk"
                                status.text = "Channel busy. Try again in a moment."
                                tones.denied()
                            }
                        } else if (generation != floorGeneration || !talkPressed) {
                            releaseGrantedFloor(active, channel, grant.requestToken)
                        } else {
                            heldFloorToken = grant.requestToken
                            button.text = "Floor granted — talking"
                            status.setTextColor(Color.rgb(8, 117, 92))
                            status.text = "Encrypted floor granted for up to ${grant.grantedTotMs / 1000} seconds."
                            tones.granted()
                            mainHandler.postDelayed(
                                { if (heldFloorToken == grant.requestToken) endTalk(active, button, status) },
                                grant.grantedTotMs.toLong(),
                            )
                        }
                    },
                    onFailure = {
                        if (generation == floorGeneration) {
                            talkPressed = false
                            button.text = "Hold to talk"
                            status.setTextColor(Color.rgb(150, 40, 40))
                            status.text = safeMessage(it)
                            tones.denied()
                        }
                    },
                )
            }
        }
    }

    private fun endTalk(active: DeviceSession, button: Button, status: TextView) {
        if (!talkPressed && heldFloorToken == null) return
        talkPressed = false
        floorGeneration++
        val token = heldFloorToken
        heldFloorToken = null
        button.text = "Hold to talk"
        status.setTextColor(Color.DKGRAY)
        status.text = "Releasing floor…"
        if (token != null) {
            val channel = selectedChannel
            if (channel != null) releaseGrantedFloor(active, channel, token, status)
        } else {
            status.text = "Released before the floor was granted."
        }
    }

    private fun releaseGrantedFloor(
        active: DeviceSession,
        channel: ChannelSummary,
        token: String,
        status: TextView? = null,
    ) {
        thread(name = "ptt-floor-release") {
            val result = runCatching { ControlApi(active.serverUrl).releaseFloor(active, channel.channelId, token) }
            runOnUiThread {
                result.fold(
                    onSuccess = {
                        status?.text = "${channel.displayName} ready."
                        tones.released()
                    },
                    onFailure = {
                        status?.setTextColor(Color.rgb(150, 40, 40))
                        status?.text = safeMessage(it)
                    },
                )
            }
        }
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
    }
}
