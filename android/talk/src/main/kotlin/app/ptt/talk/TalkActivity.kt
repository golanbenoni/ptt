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
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.media.MediaRecorder
import android.media.MediaPlayer
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.OpenableColumns
import android.graphics.pdf.PdfRenderer
import android.text.InputType
import android.text.Editable
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.TextWatcher
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.util.LruCache
import app.ptt.crypto.persistence.EncryptedHistoryRecord
import app.ptt.crypto.persistence.EncryptedSignalProtocolStore
import java.security.MessageDigest
import java.util.UUID
import kotlin.concurrent.thread
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.util.KeyHelper

/** Production application shell. The legacy encrypted-tone fixture lives in tools/net. */
class TalkActivity : Activity() {
    private enum class ChatWorkspace { MESSAGES, MEDIA, BRIEF, MEMBERS, SECURITY }
    private enum class HomeConversationFilter { ALL, UNREAD, MENTIONS, PINNED }

    private data class ConversationSummary(
        val channel: ChannelSummary,
        val preview: String,
        val lastActivity: java.time.Instant?,
        val unreadCount: Int,
        val hasMention: Boolean,
        val hasDraft: Boolean,
        val searchEntries: List<ConversationSearchEntry>,
        val starredMessages: List<ChatConversationMessage>,
        val preferences: ChatConversationPreferences,
        val threadAttention: List<ThreadAttentionSummary> = emptyList(),
        val rootHasMention: Boolean = false,
        val rootAttentionPreview: String = preview,
    )

    private data class ThreadAttentionSummary(
        val rootId: UUID,
        val unreadCount: Int,
        val preview: String,
        val lastActivity: java.time.Instant,
        val hasMention: Boolean,
    )

    private data class ConversationSearchEntry(
        val sentAt: java.time.Instant,
        val searchableText: String,
        val preview: String,
    )

    private data class ActivitySnapshot(
        val conversations: List<ConversationSummary>,
        val operations: List<OperationRun>,
        val history: List<EncryptedHistoryRecord>,
        val operationsError: String?,
    )

    private data class ChatRefreshSnapshot(
        val conversation: List<ChatConversationMessage>,
        val pending: Int,
        val devices: List<ChannelDevice>,
        val typing: List<ChatTypingParticipant>,
    )

    private lateinit var credentials: SecureDeviceStore
    private var session: DeviceSession? = null
    private var incomingAction: String? = null
    private var incomingToken: String? = null
    private var incomingDeviceInvite: DeviceLinkInvite? = null
    private var configuredServer: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var chatTypingGeneration = 0L
    private val tones = ToneFeedback()
    private var recoveryScreen = 0
    private var selectedChannel: ChannelSummary? = null
    private var talkPressed = false
    private var armButton: Button? = null
    private var talkButton: Button? = null
    private var talkButtonCompact = false
    private var talkStatusView: TextView? = null
    private var compactPttSummaryView: Button? = null
    private var homeConversationFilter = HomeConversationFilter.ALL
    private var homeConversationQuery = ""
    private var pendingChatSearchQuery: String? = null
    private var requestedChatThreadRootId: UUID? = null
    private var presenceStatusView: TextView? = null
    private var sosButton: Button? = null
    private var sosActive = false
    private var receiverRegistered = false
    private var pendingChatChannel: ChannelSummary? = null
    private var pendingChatKind: ChatContentKind = ChatContentKind.FILE
    private var pendingChatThreadRootId: UUID? = null
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
    private var chatVoiceThreadRootId: UUID? = null
    private var chatVoicePlayer: MediaPlayer? = null
    private var chatVoiceMessageId: UUID? = null
    private var chatVoicePlaybackRate = 1f
    private var chatVoicePlaybackFile: java.io.File? = null
    private var chatReplyTo: UUID? = null
    private var chatEditing: UUID? = null
    private var currentChatWorkspace = ChatWorkspace.MESSAGES
    private var openChatRequested = false
    private var requestedChatChannelId: String? = null
    private val chatTransferCancelled = java.util.concurrent.atomic.AtomicBoolean(false)
    private var chatTransferStatusView: TextView? = null
    private var chatCancelTransferButton: Button? = null
    private val chatThumbnailBitmaps = object : LruCache<UUID, Bitmap>(16 * 1024) {
        override fun sizeOf(key: UUID, value: Bitmap): Int = value.byteCount / 1024
    }
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
                    PttSessionService.STATE_PREPARING,
                    PttSessionService.STATE_RECONNECTING,
                    PttSessionService.STATE_REQUESTING -> {
                        talkButton?.isEnabled = false
                        talkButton?.text = when (state) {
                            PttSessionService.STATE_REQUESTING -> talkButtonLabel("Requesting floor…", "Wait")
                            PttSessionService.STATE_RECONNECTING -> talkButtonLabel("Reconnecting…", "Wait")
                            else -> talkButtonLabel("Hold to talk", "Hold")
                        }
                        talkStatusView?.setTextColor(colorMuted())
                    }
                    PttSessionService.STATE_READY -> {
                        talkPressed = false
                        talkButton?.text = talkButtonLabel("Hold to talk", "Hold")
                        talkButton?.isEnabled = selectedChannel?.role != "listen" &&
                            PttSessionService.isArmed(this@TalkActivity) && !CallSessionService.isActive()
                        talkStatusView?.setTextColor(colorSuccess())
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_GRANTED -> {
                        talkButton?.isEnabled = !CallSessionService.isActive()
                        talkButton?.text = talkButtonLabel("Floor granted — securing…", "Wait")
                        talkStatusView?.setTextColor(colorSuccess())
                        if (!detail.startsWith("Silent SOS")) tones.granted()
                    }
                    PttSessionService.STATE_TRANSMITTING -> {
                        talkButton?.isEnabled = !CallSessionService.isActive()
                        talkButton?.text = talkButtonLabel("Floor granted — talking", "Talk")
                        talkStatusView?.setTextColor(colorSuccess())
                    }
                    PttSessionService.STATE_DENIED -> {
                        talkPressed = false
                        talkButton?.isEnabled = !CallSessionService.isActive()
                        talkButton?.text = talkButtonLabel("Hold to talk", "Hold")
                        talkStatusView?.setTextColor(colorDanger())
                        tones.denied()
                        sosActive = false
                        sosButton?.text = "Start priority SOS voice"
                    }
                    PttSessionService.STATE_ERROR -> {
                        talkPressed = false
                        talkButton?.isEnabled = selectedChannel != null &&
                            PttSessionService.isArmed(this@TalkActivity) && !CallSessionService.isActive()
                        talkButton?.text = talkButtonLabel("Hold to talk", "Hold")
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
                    PttSessionService.STATE_RECEIVING,
                    PttSessionService.STATE_PLAYED,
                    PttSessionService.STATE_HISTORY_UPDATED,
                    PttSessionService.STATE_HISTORY_DEFERRED -> {
                        val emergency = detail.startsWith("SOS ")
                        talkStatusView?.setTextColor(if (emergency) colorDanger() else colorSuccess())
                        if (emergency) tones.emergency()
                    }
                }
                refreshCompactPttSummary()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Release builds always prevent screenshots and recents thumbnails. Debug UI
        // fixtures opt in explicitly so store/accessibility automation can capture the
        // real production surface instead of maintaining a separate visual mock.
        if (BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_DEBUG_ALLOW_SCREENSHOTS, false)) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
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
        requestedChatThreadRootId = intent.getStringExtra(PttMessagingService.EXTRA_CHAT_THREAD_ROOT_ID)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
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
        intent.getStringExtra(PttMessagingService.EXTRA_CHAT_THREAD_ROOT_ID)?.let {
            requestedChatThreadRootId = runCatching { UUID.fromString(it) }.getOrNull()
        }
        acceptDeepLink(intent)
        if (session == null) {
            when {
                incomingDeviceInvite != null -> showIncomingDeviceLink(requireNotNull(incomingDeviceInvite))
                incomingAction == "recover" -> showRecovery()
                else -> showOnboarding()
            }
        } else if (openChatRequested) {
            selectedChannel?.takeIf {
                requestedChatChannelId == null || it.channelId.equals(requestedChatChannelId, true)
            }?.let {
                val requestedThread = requestedChatThreadRootId
                openChatRequested = false
                requestedChatChannelId = null
                requestedChatThreadRootId = null
                showChat(requireNotNull(session), it, threadRootId = requestedThread)
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
            PttSessionService.arm(this, selectedChannel)
            armButton?.text = "Disconnect background session"
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
        val threadRootId = pendingChatThreadRootId
        pendingChatChannel = null
        pendingChatThreadRootId = null
        chatTransferCancelled.set(false)
        chatTransferStatusView?.text = "Encrypting attachment…"
        chatCancelTransferButton?.visibility = View.VISIBLE
        thread(name = "ptt-chat-attachment-send") {
            val result = runCatching {
                val bytes = readBoundedChatAttachment(uri)
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: "Attachment"
                val mime = contentResolver.getType(uri) ?: "application/octet-stream"
                val thumbnail = generateChatThumbnail(uri, bytes, mime)
                EncryptedChatClient(this, active).sendAttachment(
                    bytes, name, mime, kind,
                    thumbnailData = thumbnail?.data,
                    thumbnailWidth = thumbnail?.width ?: 0,
                    thumbnailHeight = thumbnail?.height ?: 0,
                    channel = channel,
                    replyTo = threadRootId,
                    onProgress = { progress -> showChatTransferProgress(progress) },
                    isCancelled = chatTransferCancelled::get,
                )
            }
            runOnUiThread {
                chatCancelTransferButton?.visibility = View.GONE
                result.fold(
                    onSuccess = { showChat(active, channel, "Attachment sent securely.", threadRootId = threadRootId) },
                    onFailure = { showChat(active, channel, safeMessage(it), threadRootId = threadRootId) },
                )
            }
        }
    }

    private data class GeneratedChatThumbnail(val data: ByteArray, val width: Int, val height: Int)

    private fun generateChatThumbnail(uri: Uri, bytes: ByteArray, mime: String): GeneratedChatThumbnail? {
        val bitmap = when {
            mime.startsWith("image/") -> {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                var sample = 1
                while (maxOf(bounds.outWidth / sample, bounds.outHeight / sample) > 960) sample *= 2
                BitmapFactory.decodeByteArray(
                    bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample },
                )
            }
            mime == "application/pdf" -> runCatching {
                contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    PdfRenderer(descriptor).use { renderer ->
                        renderer.openPage(0).use { page ->
                            val scale = minOf(1f, 480f / maxOf(page.width, page.height).toFloat())
                            val rendered = Bitmap.createBitmap(
                                maxOf(1, (page.width * scale).toInt()),
                                maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888,
                            )
                            rendered.eraseColor(Color.WHITE)
                            page.render(rendered, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            rendered
                        }
                    }
                }
            }.getOrNull()
            mime.startsWith("video/") -> runCatching {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(this, uri)
                    retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } finally {
                    retriever.release()
                }
            }.getOrNull()
            else -> null
        } ?: return null
        var scaled: Bitmap? = null
        return try {
            val scale = minOf(1f, 480f / maxOf(bitmap.width, bitmap.height).toFloat())
            val width = maxOf(1, (bitmap.width * scale).toInt())
            val height = maxOf(1, (bitmap.height * scale).toInt())
            val rendered = if (width == bitmap.width && height == bitmap.height) bitmap else {
                Bitmap.createScaledBitmap(bitmap, width, height, true)
            }
            scaled = rendered
            var quality = 78
            var output = java.io.ByteArrayOutputStream()
            rendered.compress(Bitmap.CompressFormat.JPEG, quality, output)
            while (output.size() > EncryptedChatCodec.MAX_THUMBNAIL_BYTES && quality > 30) {
                quality -= 10
                output = java.io.ByteArrayOutputStream()
                rendered.compress(Bitmap.CompressFormat.JPEG, quality, output)
            }
            output.toByteArray().takeIf {
                it.isNotEmpty() && it.size <= EncryptedChatCodec.MAX_THUMBNAIL_BYTES
            }?.let { GeneratedChatThumbnail(it, width, height) }
        } finally {
            if (scaled !== bitmap) scaled?.recycle()
            bitmap.recycle()
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
        content.addView(versionLabel())
        content.addView(body("Open your team invitation here. Your server and encryption setup are handled automatically."))
        val invitation = card()
        invitation.addView(sectionTitle("Open your team invite", "GET STARTED"))
        invitation.addView(body("Open the invitation email on this phone, then tap Join PTT Talk. Setup finishes here automatically."))
        val openEmail = primaryAction("Open email")
        invitation.addView(openEmail)
        addCard(content, invitation)
        val alternatives = card()
        val revealAlternatives = action("Other setup options  ›").apply {
            contentDescription = "Show other setup options"
            setOnClickListener {
                alternatives.removeAllViews()
                alternatives.addView(sectionTitle("Other setup options"))
                alternatives.addView(action("Enter invite manually  ›").apply { setOnClickListener { showManualInvitation() } })
                alternatives.addView(action("Link a second device  ›").apply { setOnClickListener { showDeviceLinkClaim() } })
                alternatives.addView(action("Recover an account  ›").apply { setOnClickListener { showRecovery() } })
            }
        }
        alternatives.addView(revealAlternatives)
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

    private fun showTalkConsole(active: DeviceSession) {
        talkButtonCompact = false
        selectedChannel = null
        talkPressed = false
        talkButton = null
        talkStatusView = null
        presenceStatusView = null
        sosButton = null
        sosActive = false
        val content = column()
        content.addView(sectionTitle("Talk", "PRIVATE TEAM VOICE"))
        content.addView(versionLabel())

        val voiceCard = card()
        voiceCard.addView(sectionTitle("Live channel", "CHOOSE WHERE TO TALK"))
        if (CallSessionService.isActive()) {
            voiceCard.addView(statusPill("A secure call is using audio. Normal PTT will return when the call ends."))
            voiceCard.addView(primaryAction("Open active call").apply {
                setOnClickListener { showCalls(active) }
            })
        }
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
        voiceCard.addView(body("Keeps secure receiving available with the screen off. After a reboot, open PTT Talk once to reconnect."))

        val channelHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        channelHeader.addView(title("Talk target", 18f), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val refreshChannels = action("Refresh").apply {
            minHeight = dp(44)
            setOnClickListener { showTalkConsole(active) }
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
        val quickTargetToggle = action("Show quick targets A · B · C")
        quickTargetRow.visibility = View.GONE
        quickTargetToggle.setOnClickListener {
            val showing = quickTargetRow.visibility == View.VISIBLE
            quickTargetRow.visibility = if (showing) View.GONE else View.VISIBLE
            quickTargetToggle.text = if (showing) "Show quick targets A · B · C" else "Hide quick targets"
        }
        voiceCard.addView(quickTargetToggle)
        voiceCard.addView(quickTargetRow)

        val talkStatus = statusPill("Select a channel to prepare its authenticated floor and relay session.")
        val talk = primaryAction("Hold to talk").apply {
            isEnabled = false
            textSize = 19f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            contentDescription = "Hold to talk. Release to stop."
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(colorAccent())
            }
            layoutParams = LinearLayout.LayoutParams(dp(176), dp(176)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                setMargins(0, dp(12), 0, dp(8))
            }
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
        voiceCard.addView(body("Hold while speaking, then release. Audio is sent only after the secure floor is granted.").apply {
            gravity = Gravity.CENTER
        })
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

        val safety = action("Contacts & safety numbers").apply {
            setOnClickListener {
                val channel = selectedChannel
                if (channel == null) talkStatus.text = "Select a channel before viewing safety numbers."
                else showSafetyNumbers(active, channel)
            }
        }
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

        val safetyCard = card()
        safetyCard.addView(sectionTitle("Safety", "VERIFY YOUR TEAM"))
        safetyCard.addView(safety)
        addCard(content, safetyCard)
        content.addView(action("Back to Chats").apply {
            contentDescription = "Back to Chats"
            setOnClickListener { showTalkHome(active) }
        }, 0)
        setContentView(appScreen(content, active, "radio"))

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
        content.addView(sectionTitle("Settings", "ACCOUNT, DEVICES & PREFERENCES"))
        content.addView(versionLabel())
        content.addView(body("Your account, linked devices, encryption, and privacy choices."))

        val accountCard = card()
        accountCard.addView(sectionTitle("Account & devices", "SECURE IDENTITY"))
        accountCard.addView(statusPill("Account ${active.aci.take(8)}…  ·  Device ${active.deviceId} of 2"))
        val deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        accountCard.addView(deviceList)
        accountCard.addView(action("Link another device  ›").apply { setOnClickListener { showActiveDeviceLink(active) } })
        addCard(content, accountCard)

        val securityCard = card()
        securityCard.addView(sectionTitle("Protected end to end", "SECURITY"))
        val status = statusPill("Loading secure device details…")
        securityCard.addView(status)
        securityCard.addView(body("Voice, messages, and attachments are encrypted between approved devices. Your server relays encrypted data and cannot read it."))
        val encryption = body("Loading device-key fingerprint…").apply {
            typeface = Typeface.MONOSPACE
            textSize = 13f
            visibility = View.GONE
        }
        securityCard.addView(action("Show technical encryption details").apply {
            setOnClickListener {
                val showing = encryption.visibility == View.VISIBLE
                encryption.visibility = if (showing) View.GONE else View.VISIBLE
                text = if (showing) "Show technical encryption details" else "Hide technical encryption details"
            }
        })
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
        setContentView(appScreen(content, active, "you"))

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
        content.addView(title("Activity"))
        content.addView(body("Mentions, operational updates, and encrypted voice in one place"))
        val attention = card()
        attention.addView(sectionTitle("Needs attention", "INBOX"))
        val attentionRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        attention.addView(attentionRows)
        addCard(content, attention)
        val savedCard = card()
        savedCard.addView(sectionTitle("Saved", "FOR LATER"))
        val savedRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        savedCard.addView(savedRows)
        addCard(content, savedCard)
        val operationsCard = card()
        operationsCard.addView(sectionTitle("Active operations", "COORDINATE"))
        val operationRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        operationsCard.addView(operationRows)
        if (channel.role == "dispatch" || channel.role == "barge") {
            operationsCard.addView(primaryAction("Start an operation").apply {
                setOnClickListener { showStartOperation(active, channel) }
            })
        }
        addCard(content, operationsCard)
        val historyCard = card()
        historyCard.addView(sectionTitle("Transmission history", "VOICE · ${channel.displayName.uppercase()}"))
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val status = body("Loading secure activity…")
        historyCard.addView(rows)
        historyCard.addView(status)
        addCard(content, historyCard)
        val root = appScreen(content, active, "activity", channel)
        setContentView(root)
        thread(name = "ptt-history-list") {
            val result = runCatching {
                val api = ControlApi(active.serverUrl)
                val channels = api.channels(active)
                val operationsResult = runCatching { api.operations(active) }
                val chat = EncryptedChatClient(this, active)
                chat.poll(channels)
                val conversations = channels.map { candidate ->
                    val items = chat.conversation(candidate.channelId)
                    ConversationSummary(
                        candidate,
                        items.lastOrNull()?.displayText ?: candidate.topic.ifBlank { "No messages yet" },
                        items.lastOrNull()?.message?.sentAt,
                        items.count { it.isUnread },
                        items.any { it.isUnread && ChatMentions.containsLocalMention(it.displayText, active.aci) },
                        chat.draft(candidate.channelId).isNotBlank(),
                        items.mapNotNull(::conversationSearchEntry),
                        items.filter { it.isStarred && !it.isDeleted },
                        chat.preferences(candidate.channelId),
                        threadAttention(items, active.aci),
                        ChatThreads.timeline(items).any {
                            it.isUnread && ChatMentions.containsLocalMention(it.displayText, active.aci)
                        },
                        rootAttentionPreview(items),
                    )
                }
                val history = EncryptedSignalProtocolStore.open(this).use { it.historyRecords(channel.channelId) }
                ActivitySnapshot(
                    conversations = conversations,
                    operations = operationsResult.getOrDefault(emptyList()),
                    history = history,
                    operationsError = operationsResult.exceptionOrNull()?.let(::safeMessage),
                )
            }
            runOnUiThread {
                if (!root.isAttachedToWindow) return@runOnUiThread
                result.fold(
                    onSuccess = { snapshot ->
                        val conversations = snapshot.conversations
                        val operations = snapshot.operations
                        val history = snapshot.history
                        attentionRows.removeAllViews()
                        val threadReplies = conversations.flatMap { summary ->
                            summary.threadAttention.map { thread -> summary.channel to thread }
                        }.sortedByDescending { (_, thread) -> thread.lastActivity }
                        threadReplies.take(8).forEach { (threadChannel, thread) ->
                            attentionRows.addView(action(
                                "${if (thread.hasMention) "@ Mention in thread" else "Thread reply"} in ${threadChannel.displayName}\n${thread.unreadCount} unread · ${thread.preview.take(100)}",
                            ).apply {
                                contentDescription = "Open thread with ${thread.unreadCount} unread replies in ${threadChannel.displayName}"
                                setOnClickListener { showChat(active, threadChannel, threadRootId = thread.rootId) }
                            })
                        }
                        val mentioned = conversations.filter {
                            it.unreadCount - it.threadAttention.sumOf(ThreadAttentionSummary::unreadCount) > 0 && it.rootHasMention
                        }
                        val unread = conversations.filter {
                            it.unreadCount - it.threadAttention.sumOf(ThreadAttentionSummary::unreadCount) > 0 && !it.rootHasMention
                        }
                        (mentioned + unread).take(8).forEach { summary ->
                            val rootUnread = (summary.unreadCount - summary.threadAttention.sumOf(ThreadAttentionSummary::unreadCount))
                                .coerceAtLeast(0)
                            attentionRows.addView(action(buildString {
                                append(if (summary.rootHasMention) "@ Mention in " else "Unread in ")
                                append(summary.channel.displayName)
                                append("\n$rootUnread unread · ${summary.rootAttentionPreview.take(100)}")
                            }).apply { setOnClickListener { showChat(active, summary.channel) } })
                        }
                        if (threadReplies.isEmpty() && mentioned.isEmpty() && unread.isEmpty()) {
                            attentionRows.addView(body("You're caught up. New mentions and messages will appear here."))
                        }

                        savedRows.removeAllViews()
                        val saved = conversations.flatMap { summary ->
                            summary.starredMessages.map { message -> summary.channel to message }
                        }.sortedByDescending { (_, message) -> message.message.sentAt }.take(20)
                        saved.forEach { (savedChannel, message) ->
                            savedRows.addView(action(
                                "★ ${savedChannel.displayName}\n${savedMessageLabel(message).take(140)}",
                            ).apply {
                                contentDescription = "Saved in ${savedChannel.displayName}, ${savedMessageLabel(message)}"
                                setOnClickListener { showChat(active, savedChannel) }
                            })
                        }
                        if (saved.isEmpty()) {
                            savedRows.addView(body("Star a message to keep it easy to find on this device."))
                        }

                        operationRows.removeAllViews()
                        val activeOperations = operations.filter { it.resolvedAt == null }
                        activeOperations.forEach { operation ->
                            val operationChannel = conversations.firstOrNull { it.channel.channelId == operation.channelId }?.channel
                            val operationCard = card()
                            operationCard.addView(title(operation.displayName, 17f))
                            operationCard.addView(body("${operation.severity.replaceFirstChar(Char::uppercase)} · ${operation.status.replace('_', ' ')} · ${operation.acknowledgementCount} acknowledged"))
                            val actions = LinearLayout(this@TalkActivity).apply { orientation = LinearLayout.HORIZONTAL }
                            actions.addView(action("Acknowledge").apply {
                                setOnClickListener {
                                    thread(name = "ptt-operation-ack") {
                                        val acknowledged = runCatching {
                                            ControlApi(active.serverUrl).acknowledgeOperation(active, operation.runId, UUID.randomUUID().toString())
                                        }
                                        runOnUiThread {
                                            status.text = acknowledged.fold({ "Operation acknowledged." }, ::safeMessage)
                                            if (acknowledged.isSuccess) showHistory(active, channel)
                                        }
                                    }
                                }
                            }, LinearLayout.LayoutParams(0, -2, 1f))
                            if (operationChannel?.role == "dispatch" || operationChannel?.role == "barge") {
                                actions.addView(action(if (operation.status == "monitoring") "Resolve" else "Monitor").apply {
                                    setOnClickListener {
                                        val next = if (operation.status == "monitoring") "resolved" else "monitoring"
                                        thread(name = "ptt-operation-status") {
                                            val changed = runCatching { ControlApi(active.serverUrl).updateOperation(active, operation.runId, next) }
                                            runOnUiThread {
                                                status.text = changed.fold({ "Operation updated." }, ::safeMessage)
                                                if (changed.isSuccess) showHistory(active, channel)
                                            }
                                        }
                                    }
                                }, LinearLayout.LayoutParams(0, -2, 1f))
                            }
                            operationCard.addView(actions)
                            operationRows.addView(operationCard, spacedParams(vertical = 5))
                        }
                        if (activeOperations.isEmpty()) {
                            operationRows.addView(body(snapshot.operationsError ?: "No active operations."))
                        }

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

    private fun showStartOperation(active: DeviceSession, channel: ChannelSummary) {
        val name = field("Operation name")
        val severities = arrayOf("routine", "priority", "critical")
        var severity = severities[0]
        val severityPicker = android.widget.Spinner(this).apply {
            adapter = android.widget.ArrayAdapter(this@TalkActivity, android.R.layout.simple_spinner_dropdown_item, severities)
            onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                    severity = severities[position]
                }

                override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
            }
        }
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(name)
            addView(severityPicker)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Start operation")
            .setMessage("Create a shared status board for ${channel.displayName}.")
            .setView(form)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Start", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val displayName = name.text.toString().trim()
                if (displayName.isBlank()) {
                    name.error = "Enter an operation name"
                    return@setOnClickListener
                }
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
                thread(name = "ptt-operation-start") {
                    val result = runCatching {
                        ControlApi(active.serverUrl).startOperation(active, channel.channelId, displayName, severity)
                    }
                    runOnUiThread {
                        result.fold(
                            onSuccess = { dialog.dismiss(); showHistory(active, channel) },
                            onFailure = {
                                name.error = safeMessage(it)
                                dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = true
                            },
                        )
                    }
                }
            }
        }
        dialog.show()
    }

    private fun showTalkHome(active: DeviceSession) = showConversationList(active)

    private fun showConversationList(active: DeviceSession, initialStatus: String? = null) {
        stopChatVoicePlayback()
        val content = column()
        val heading = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(LinearLayout(this@TalkActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(title("Chats", 34f))
                addView(body("🔒 End-to-end encrypted · ${versionLabel().text}"))
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(primaryAction("New").apply {
                contentDescription = "New conversation"
                minWidth = dp(64)
                setOnClickListener { showNewConversation(active) }
            }, LinearLayout.LayoutParams(-2, -2))
        }
        content.addView(heading)
        val conversationSearch = field("Search conversations", homeConversationQuery).apply {
            contentDescription = "Search conversations"
            inputType = InputType.TYPE_CLASS_TEXT
        }
        content.addView(conversationSearch)
        val filterButtons = HomeConversationFilter.values().associateWith { filter ->
            action(filter.name.lowercase().replaceFirstChar(Char::uppercase))
        }
        val filterBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = rounded(colorSurfaceRaised(), 16f, colorBorder(), 1)
            filterButtons.forEach { (_, button) ->
                addView(button, LinearLayout.LayoutParams(0, -2, 1f).apply {
                    setMargins(dp(2), 0, dp(2), 0)
                })
            }
        }
        content.addView(filterBar, spacedParams(vertical = 5))
        initialStatus?.let { content.addView(statusPill(it)) }
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(rows)
        val loading = statusPill("Loading encrypted conversations…")
        content.addView(loading)
        val root = appScreen(content, active, "home", selectedChannel)
        setContentView(root)

        var loadedSummaries = emptyList<ConversationSummary>()
        fun refreshFilterButtons() {
            filterButtons.forEach { (filter, button) ->
                val selected = filter == homeConversationFilter
                button.setTextColor(if (selected) colorAccent() else colorMuted())
                button.background = if (selected) {
                    rounded(withAlpha(colorAccent(), 28), 13f)
                } else {
                    rounded(Color.TRANSPARENT, 13f)
                }
                button.contentDescription = if (selected) {
                    "${button.text}, selected"
                } else {
                    button.text.toString()
                }
            }
        }
        fun renderConversationRows() {
            rows.removeAllViews()
            val query = homeConversationQuery.trim()
            val filtered = loadedSummaries.filter { summary ->
                val matchesFilter = when (homeConversationFilter) {
                    HomeConversationFilter.ALL -> true
                    HomeConversationFilter.UNREAD -> summary.unreadCount > 0
                    HomeConversationFilter.MENTIONS -> summary.hasMention
                    HomeConversationFilter.PINNED -> summary.preferences.isPinned
                }
                matchesFilter && (query.isBlank() ||
                    summary.channel.displayName.contains(query, ignoreCase = true) ||
                    summary.channel.topic.contains(query, ignoreCase = true) ||
                    summary.preview.contains(query, ignoreCase = true) ||
                    matchingConversationSearchEntry(summary, query) != null)
            }
            val activeRows = filtered.filterNot { it.preferences.isArchived }
            val archivedRows = if (homeConversationFilter == HomeConversationFilter.ALL) {
                filtered.filter { it.preferences.isArchived }
            } else {
                emptyList()
            }
            if (activeRows.isEmpty() && archivedRows.isEmpty()) {
                val empty = card()
                val message = when {
                    loadedSummaries.isEmpty() -> "Ask an administrator to add you to a channel, or start a direct message with a teammate."
                    query.isNotBlank() -> "No conversations match your search."
                    homeConversationFilter == HomeConversationFilter.UNREAD -> "You're caught up."
                    homeConversationFilter == HomeConversationFilter.MENTIONS -> "No unread mentions."
                    homeConversationFilter == HomeConversationFilter.PINNED -> "No pinned conversations yet."
                    else -> "No conversations match this view."
                }
                empty.addView(sectionTitle(if (loadedSummaries.isEmpty()) "No conversations yet" else "Nothing here", "YOUR TEAM"))
                empty.addView(body(message))
                if (loadedSummaries.isEmpty()) {
                    empty.addView(primaryAction("Start a conversation").apply {
                        setOnClickListener { showNewConversation(active) }
                    })
                }
                addCard(rows, empty)
            } else {
                activeRows.forEach { rows.addView(conversationRow(active, it)) }
                if (archivedRows.isNotEmpty()) {
                    rows.addView(body("ARCHIVED").apply {
                        typeface = Typeface.DEFAULT_BOLD
                        letterSpacing = .08f
                        setPadding(0, dp(18), 0, dp(4))
                    })
                    archivedRows.forEach { rows.addView(conversationRow(active, it)) }
                }
            }
        }
        filterButtons.forEach { (filter, button) ->
            button.setOnClickListener {
                homeConversationFilter = filter
                refreshFilterButtons()
                renderConversationRows()
            }
        }
        refreshFilterButtons()
        conversationSearch.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(value: Editable?) {
                homeConversationQuery = value?.toString().orEmpty()
                renderConversationRows()
            }
        })

        thread(name = "ptt-conversation-list") {
            val result = runCatching {
                val api = ControlApi(active.serverUrl)
                val channels = api.channels(active)
                val client = EncryptedChatClient(this, active)
                client.poll(channels)
                channels.map { channel ->
                    val conversation = client.conversation(channel.channelId)
                    val preferences = client.preferences(channel.channelId)
                    val draft = client.draft(channel.channelId).trim()
                    val latest = conversation.lastOrNull()
                    val preview = when {
                        draft.isNotEmpty() -> "Draft: $draft"
                        latest == null -> channel.topic.ifBlank { "No messages yet" }
                        latest.message.kind == ChatContentKind.TEXT ->
                            callTimelineLabel(latest.displayText) ?: ChatMentions.rendered(latest.displayText)
                        latest.message.kind == ChatContentKind.VOICE -> "Voice message"
                        latest.message.kind == ChatContentKind.VIDEO -> "Video"
                        else -> "File"
                    }
                    ConversationSummary(
                        channel = channel,
                        preview = preview,
                        lastActivity = latest?.message?.sentAt,
                        unreadCount = conversation.count { it.isUnread },
                        hasMention = conversation.any {
                            it.isUnread && ChatMentions.containsLocalMention(it.displayText, active.aci)
                        },
                        hasDraft = draft.isNotEmpty(),
                        searchEntries = conversation.mapNotNull(::conversationSearchEntry),
                        starredMessages = conversation.filter { it.isStarred && !it.isDeleted },
                        preferences = preferences,
                        threadAttention = threadAttention(conversation, active.aci),
                        rootHasMention = ChatThreads.timeline(conversation).any {
                            it.isUnread && ChatMentions.containsLocalMention(it.displayText, active.aci)
                        },
                        rootAttentionPreview = rootAttentionPreview(conversation),
                    )
                }.sortedWith(compareByDescending<ConversationSummary> { it.preferences.isPinned }
                    .thenByDescending { it.lastActivity })
            }
            runOnUiThread {
                if (!root.isAttachedToWindow) return@runOnUiThread
                result.fold(
                    onSuccess = { summaries ->
                        val available = summaries.map { it.channel }
                        val requestedConversation = if (openChatRequested) {
                            summaries.firstOrNull {
                                requestedChatChannelId == null ||
                                    it.channel.channelId.equals(requestedChatChannelId, true)
                            }
                        } else {
                            null
                        }
                        val preferred = requestedConversation?.channel ?: available.firstOrNull {
                            it.channelId.equals(selectedChannel?.channelId, true)
                        } ?: available.firstOrNull()
                        selectedChannel = preferred
                        refreshCompactPttSummary()
                        talkButton?.isEnabled = preferred != null && preferred.role != "listen" &&
                            PttSessionService.isArmed(this@TalkActivity)
                        talkStatusView?.text = if (talkButton?.isEnabled == true) "Ready" else "Not connected"
                        if (preferred != null && PttSessionService.isArmed(this@TalkActivity)) {
                            PttSessionService.prepare(this@TalkActivity, preferred)
                        }
                        loadedSummaries = summaries
                        renderConversationRows()
                        loading.text = "Messages and attachments remain end-to-end encrypted."
                        if (openChatRequested && requestedConversation != null) {
                            val requestedThread = requestedChatThreadRootId
                            openChatRequested = false
                            requestedChatChannelId = null
                            requestedChatThreadRootId = null
                            showChat(active, requestedConversation.channel, threadRootId = requestedThread)
                        }
                    },
                    onFailure = {
                        loading.setTextColor(colorDanger())
                        loading.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun conversationRow(active: DeviceSession, summary: ConversationSummary): View {
        val query = homeConversationQuery.trim()
        val matchingEntry = matchingConversationSearchEntry(summary, query)
        val displayedPreview = matchingEntry?.let { "Match: ${it.preview}" } ?: summary.preview
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(10), dp(4), dp(10))
            minimumHeight = dp(76)
            background = rounded(Color.TRANSPARENT, 0f)
            contentDescription = "Open conversation ${summary.channel.displayName}, ${summary.unreadCount} unread, $displayedPreview"
            setOnClickListener {
                selectedChannel = summary.channel
                if (PttSessionService.isArmed(this@TalkActivity)) {
                    PttSessionService.prepare(this@TalkActivity, summary.channel)
                }
                currentChatWorkspace = ChatWorkspace.MESSAGES
                pendingChatSearchQuery = if (matchingEntry != null) query else null
                showChat(active, summary.channel)
            }
        }
        val avatarLabel = when {
            summary.channel.isAnnouncement -> "📣"
            summary.channel.kind == "direct" -> summary.channel.displayName.trim().firstOrNull()?.uppercase() ?: "•"
            else -> "#"
        }
        row.addView(TextView(this).apply {
            text = avatarLabel
            textSize = 20f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            background = rounded(conversationAvatarColor(summary.channel.channelId), 28f)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(52), dp(52)).apply { setMargins(0, 0, dp(13), 0) })
        row.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(this@TalkActivity).apply {
                text = buildString {
                    append(summary.channel.displayName)
                    if (summary.preferences.isPinned) append("  • pinned")
                    if (summary.preferences.isMuted) append("  • muted")
                }
                textSize = 17f
                setTextColor(colorText())
                typeface = Typeface.create("sans-serif-medium", if (summary.unreadCount > 0) Typeface.BOLD else Typeface.NORMAL)
                maxLines = 1
            })
            addView(TextView(this@TalkActivity).apply {
                text = (if (summary.hasDraft) "Draft · " else "") + displayedPreview.take(140)
                textSize = 14f
                setTextColor(if (summary.hasDraft) colorDanger() else colorMuted())
                maxLines = 2
            })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        if (summary.unreadCount > 0) {
            row.addView(TextView(this).apply {
                text = minOf(summary.unreadCount, 99).toString()
                textSize = 12f
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
                background = rounded(if (summary.hasMention) colorDanger() else colorAccent(), 14f)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(28), dp(28)).apply { setMargins(dp(8), 0, 0, 0) })
        }
        return row
    }

    private fun showNewConversation(active: DeviceSession) {
        val waiting = AlertDialog.Builder(this)
            .setTitle("New conversation")
            .setMessage("Loading your team directory…")
            .setNegativeButton("Cancel", null)
            .show()
        thread(name = "ptt-new-conversation-directory") {
            val result = runCatching { ControlApi(active.serverUrl).directory(active) }
            runOnUiThread {
                waiting.dismiss()
                result.fold(
                    onSuccess = { members ->
                        if (members.isEmpty()) {
                            AlertDialog.Builder(this).setTitle("No teammates available")
                                .setMessage("Ask an administrator to invite another team member.")
                                .setPositiveButton("Done", null).show()
                            return@fold
                        }
                        val selected = BooleanArray(members.size)
                        val groupName = field("Group name (for 2 or more teammates)")
                        val container = LinearLayout(this).apply {
                            orientation = LinearLayout.VERTICAL
                            setPadding(dp(20), 0, dp(20), 0)
                            addView(body("Choose one teammate for a direct message, or up to seven for a group."))
                            addView(groupName)
                        }
                        AlertDialog.Builder(this)
                            .setTitle("New conversation")
                            .setView(container)
                            .setMultiChoiceItems(members.map { it.displayName }.toTypedArray(), selected) { dialog, which, checked ->
                                if (checked && selected.count { it } > 7) {
                                    selected[which] = false
                                    (dialog as AlertDialog).listView.setItemChecked(which, false)
                                }
                            }
                            .setNegativeButton("Cancel", null)
                            .setPositiveButton("Create") { _, _ ->
                                val chosen = members.filterIndexed { index, _ -> selected[index] }
                                if (chosen.isEmpty()) {
                                    showConversationList(active, "Choose at least one teammate.")
                                } else {
                                    val kind = if (chosen.size == 1) "direct" else "group"
                                    val name = if (kind == "direct") "" else groupName.text.toString().trim()
                                        .ifBlank { chosen.joinToString(", ") { it.displayName }.take(80) }
                                    showConversationList(active, "Creating encrypted conversation…")
                                    thread(name = "ptt-create-conversation") {
                                        val created = runCatching {
                                            ControlApi(active.serverUrl).createConversation(
                                                active, kind, chosen.map { it.aci }, name,
                                            )
                                        }
                                        runOnUiThread {
                                            created.fold(
                                                onSuccess = {
                                                    currentChatWorkspace = ChatWorkspace.MESSAGES
                                                    showChat(active, it, "Conversation ready.")
                                                },
                                                onFailure = { showConversationList(active, safeMessage(it)) },
                                            )
                                        }
                                    }
                                }
                            }.show()
                    },
                    onFailure = { showConversationList(active, safeMessage(it)) },
                )
            }
        }
    }

    private fun showChat(
        active: DeviceSession,
        channel: ChannelSummary,
        initialStatus: String? = null,
        workspace: ChatWorkspace = currentChatWorkspace,
        threadRootId: UUID? = null,
    ) {
        val effectiveWorkspace = if (threadRootId == null) workspace else ChatWorkspace.MESSAGES
        currentChatWorkspace = effectiveWorkspace
        val requestedSearch = pendingChatSearchQuery?.trim().orEmpty()
        pendingChatSearchQuery = null
        val content = column()
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(action(if (threadRootId == null) "‹ Chats" else "‹ Conversation").apply {
                contentDescription = if (threadRootId == null) "Back to Chats" else "Back to conversation"
                setOnClickListener {
                    thread(name = "ptt-chat-typing-stop") {
                        runCatching { EncryptedChatClient(this@TalkActivity, active).sendTyping(channel, false, threadRootId) }
                    }
                    if (threadRootId == null) showTalkHome(active) else showChat(active, channel)
                }
            }, LinearLayout.LayoutParams(-2, -2).apply { setMargins(0, 0, dp(10), 0) })
            addView(title(if (threadRootId == null) channel.displayName else "Thread", 24f), LinearLayout.LayoutParams(0, -2, 1f))
            if (threadRootId == null) {
                addView(action("Call").apply {
                    contentDescription = "Start an encrypted voice call with ${channel.displayName}"
                    isEnabled = !CallSessionService.isActive()
                    setOnClickListener { confirmAndStartCall(active, channel) }
                }, LinearLayout.LayoutParams(-2, -2).apply { setMargins(dp(8), 0, 0, 0) })
            }
        }
        content.addView(header)
        content.addView(body(if (threadRootId == null) "🔒 End-to-end encrypted" else "🔒 Replies in ${channel.displayName} are end-to-end encrypted"))
        if (threadRootId != null) {
            val threadPreference = runCatching {
                EncryptedChatClient(this, active).threadNotificationPreference(channel.channelId, threadRootId)
            }.getOrDefault(ChatThreadNotificationPreference.AUTOMATIC)
            val threadActions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            fun threadPreferenceAction(label: String, value: ChatThreadNotificationPreference) = action(label).apply {
                setOnClickListener {
                    val result = runCatching {
                        EncryptedChatClient(this@TalkActivity, active)
                            .saveThreadNotificationPreference(channel.channelId, threadRootId, value)
                    }
                    showChat(
                        active, channel,
                        if (result.isSuccess) "Thread notification preference updated on this device."
                        else safeMessage(result.exceptionOrNull()!!),
                        threadRootId = threadRootId,
                    )
                }
            }
            threadActions.addView(threadPreferenceAction(
                if (threadPreference == ChatThreadNotificationPreference.FOLLOWING) "Following" else "Follow",
                ChatThreadNotificationPreference.FOLLOWING,
            ), LinearLayout.LayoutParams(0, -2, 1f))
            threadActions.addView(threadPreferenceAction(
                if (threadPreference == ChatThreadNotificationPreference.MUTED) "Muted" else "Mute",
                ChatThreadNotificationPreference.MUTED,
            ), LinearLayout.LayoutParams(0, -2, 1f))
            threadActions.addView(threadPreferenceAction(
                if (threadPreference == ChatThreadNotificationPreference.AUTOMATIC) "Automatic ✓" else "Automatic",
                ChatThreadNotificationPreference.AUTOMATIC,
            ), LinearLayout.LayoutParams(0, -2, 1f))
            content.addView(threadActions)
        }
        if (threadRootId == null && channel.topic.isNotBlank()) content.addView(body(channel.topic))
        if (threadRootId == null && effectiveWorkspace != ChatWorkspace.MESSAGES) {
            content.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12), dp(8), dp(12), dp(8))
                background = rounded(colorSurfaceRaised(), 16f)
                addView(action("‹ Messages").apply {
                    setOnClickListener { showChat(active, channel, workspace = ChatWorkspace.MESSAGES) }
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(body(effectiveWorkspace.name.lowercase().replaceFirstChar(Char::uppercase)).apply {
                    gravity = Gravity.END or Gravity.CENTER_VERTICAL
                    typeface = Typeface.DEFAULT_BOLD
                }, LinearLayout.LayoutParams(0, -2, 1f))
            }, spacedParams(vertical = 5))
        }
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
        val preferenceDetails = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        preferenceDetails.addView(preferenceRow)
        preferenceDetails.addView(body("Retention: ${channel.retentionDays} days · membership epoch ${channel.membershipEpoch}"))
        preferenceDetails.visibility = View.GONE
        val preferenceToggle = action("More").apply {
            contentDescription = "More conversation options"
            setOnClickListener {
                val destinations = arrayOf("Shared media", "Pinned brief", "Members", "Encryption details", "Conversation options")
                AlertDialog.Builder(this@TalkActivity)
                    .setTitle(channel.displayName)
                    .setItems(destinations) { _, which ->
                        when (which) {
                            0 -> showChat(active, channel, workspace = ChatWorkspace.MEDIA)
                            1 -> showChat(active, channel, workspace = ChatWorkspace.BRIEF)
                            2 -> showChat(active, channel, workspace = ChatWorkspace.MEMBERS)
                            3 -> showChat(active, channel, workspace = ChatWorkspace.SECURITY)
                            else -> {
                                preferenceDetails.visibility = View.VISIBLE
                                text = "Hide options"
                            }
                        }
                    }
                    .setNegativeButton("Cancel", null)
                    .show()
            }
        }
        preferenceDetails.addView(action("Participants and roles").apply {
            setOnClickListener {
                thread(name = "ptt-chat-participants") {
                    val result = runCatching {
                        ControlApi(active.serverUrl).channelDevices(active, channel.channelId)
                            .groupBy { it.aci.lowercase() }.map { (aci, devices) ->
                                val tag = java.security.MessageDigest.getInstance("SHA-256")
                                    .digest(aci.encodeToByteArray()).take(2)
                                    .joinToString("") { "%02X".format(it.toInt() and 0xff) }
                                val profile = devices.first().displayName.trim()
                                val name = if (aci == active.aci.lowercase()) "You"
                                    else profile.ifBlank { "Encrypted teammate $tag" }
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
        preferenceDetails.addView(action("Refresh messages").apply {
            setOnClickListener { showChat(active, channel) }
        })
        val rows = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        val status = statusPill(initialStatus ?: "Checking for new messages…")
        chatTransferStatusView = status
        val search = EditText(this).apply {
            hint = "Search messages"
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
            setTextColor(colorText())
            setHintTextColor(colorMuted())
            background = rounded(colorSurfaceRaised(), 16f)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            contentDescription = "Search encrypted messages"
            if (requestedSearch.isNotEmpty()) setText(requestedSearch)
            visibility = if (requestedSearch.isEmpty()) View.GONE else View.VISIBLE
        }
        val searchToggle = action(if (requestedSearch.isEmpty()) "Search messages" else "Close search").apply {
            setOnClickListener {
                val showing = search.visibility == View.VISIBLE
                search.visibility = if (showing) View.GONE else View.VISIBLE
                text = if (showing) "Search messages" else "Close search"
                if (showing) search.setText("") else search.requestFocus()
            }
        }
        val conversationTools = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(searchToggle, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(0, 0, dp(4), 0) })
            if (threadRootId == null) {
                addView(preferenceToggle, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, 0, 0) })
            }
        }
        content.addView(conversationTools)
        if (threadRootId == null) content.addView(preferenceDetails)
        content.addView(search)
        content.addView(rows)
        content.addView(status)
        val typingIndicator = body("").apply {
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            contentDescription = "Encrypted typing activity"
        }
        content.addView(typingIndicator)
        val cancelTransfer = action("Cancel attachment transfer").apply {
            visibility = View.GONE
            contentDescription = "Cancel encrypted attachment transfer"
            setOnClickListener {
                chatTransferCancelled.set(true)
                isEnabled = false
                status.text = "Cancelling encrypted transfer…"
            }
        }
        chatCancelTransferButton = cancelTransfer
        content.addView(cancelTransfer)

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
        val mentionSuggestions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val mentionScroll = android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            visibility = View.GONE
            contentDescription = "Mention suggestions"
            addView(mentionSuggestions)
        }
        var mentionAcis: List<String> = emptyList()
        fun updateMentionSuggestions() {
            val suggestions = ChatMentions.suggestions(mentionAcis, active.aci, composer.text.toString())
            mentionSuggestions.removeAllViews()
            mentionScroll.visibility = if (suggestions.isEmpty()) View.GONE else View.VISIBLE
            suggestions.forEach { mention ->
                mentionSuggestions.addView(action("@${mention.label}").apply {
                    contentDescription = "Mention ${mention.label}"
                    setOnClickListener {
                        composer.setText(ChatMentions.insert(composer.text.toString(), mention))
                        composer.setSelection(composer.text.length)
                        composer.requestFocus()
                    }
                })
            }
        }
        composer.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val typing = !s.isNullOrBlank()
                val generation = ++chatTypingGeneration
                mainHandler.postDelayed({
                    if (generation != chatTypingGeneration || !composer.isAttachedToWindow) return@postDelayed
                    thread(name = "ptt-chat-typing") {
                        runCatching {
                            EncryptedChatClient(this@TalkActivity, active)
                                .sendTyping(channel, typing, threadRootId)
                        }
                    }
                }, 250)
                runCatching {
                    EncryptedChatClient(this@TalkActivity, active)
                        .saveDraft(channel.channelId, s?.toString().orEmpty())
                }
                updateMentionSuggestions()
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        val composerContext = body("").apply { visibility = View.GONE }
        fun updateComposerContext() {
            val target = chatEditing ?: chatReplyTo ?: threadRootId
            if (target == null) {
                composerContext.visibility = View.GONE
                composerContext.isClickable = false
            } else {
                composerContext.visibility = View.VISIBLE
                composerContext.text = when {
                    chatEditing != null -> "Editing message · tap to cancel"
                    threadRootId != null -> "Replying in thread"
                    else -> "Replying to message · tap to cancel"
                }
                composerContext.isClickable = chatEditing != null || chatReplyTo != null
            }
        }
        composerContext.setOnClickListener {
            if (threadRootId != null && chatEditing == null && chatReplyTo == null) return@setOnClickListener
            chatEditing = null
            chatReplyTo = null
            updateComposerContext()
        }
        updateComposerContext()
        content.addView(composerContext)
        content.addView(mentionScroll)
        thread(name = "ptt-chat-mention-participants") {
            val acis = runCatching {
                ControlApi(active.serverUrl).channelDevices(active, channel.channelId).map { it.aci }
            }.getOrDefault(emptyList())
            runOnUiThread {
                if (composer.isAttachedToWindow) {
                    mentionAcis = acis
                    updateMentionSuggestions()
                }
            }
        }
        val sendMessage = primaryAction("Send").apply {
            minWidth = dp(72)
            contentDescription = "Send message"
            setOnClickListener {
                val text = composer.text.toString().trim()
                if (text.isEmpty()) return@setOnClickListener
                isEnabled = false
                status.text = "Sending securely…"
                thread(name = "ptt-chat-text-send") {
                    val result = runCatching {
                        val client = EncryptedChatClient(this@TalkActivity, active)
                        runCatching { client.sendTyping(channel, false, threadRootId) }
                        chatEditing?.let { client.editMessage(text, it, channel) }
                            ?: client.sendText(text, channel, threadRootId ?: chatReplyTo)
                    }
                    runOnUiThread {
                        result.fold(
                            onSuccess = {
                                EncryptedChatClient(this@TalkActivity, active).saveDraft(channel.channelId, "")
                                chatEditing = null
                                chatReplyTo = null
                                showChat(active, channel, "Message sent securely.", threadRootId = threadRootId)
                            },
                            onFailure = {
                                val pending = runCatching { EncryptedChatClient(this@TalkActivity, active).pendingSendCount() }.getOrDefault(0)
                                if (pending > 0) {
                                    EncryptedChatClient(this@TalkActivity, active).saveDraft(channel.channelId, "")
                                    chatEditing = null
                                    chatReplyTo = null
                                    showChat(active, channel, "Message queued. It will send when the connection returns.", threadRootId = threadRootId)
                                } else {
                                    isEnabled = true
                                    status.text = safeMessage(it)
                                }
                            },
                        )
                    }
                }
            }
        }
        val largeTextComposer = resources.configuration.fontScale >= 1.5f
        val composerRow = LinearLayout(this).apply {
            orientation = if (largeTextComposer) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            if (largeTextComposer) {
                addView(composer, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ))
                addView(sendMessage, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    dp(54),
                ).apply { setMargins(0, dp(8), 0, 0) })
            } else {
                addView(composer, LinearLayout.LayoutParams(
                    0,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    1f,
                ).apply { setMargins(0, 0, dp(8), 0) })
                addView(sendMessage, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    dp(54),
                ))
            }
        }
        content.addView(composerRow)
        val canPost = !channel.isAnnouncement || channel.role in setOf("dispatch", "barge")
        if (!canPost) {
            composerRow.visibility = View.GONE
            content.addView(statusPill("Announcements are read-only for your role."))
        }

        val attachmentRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            visibility = View.GONE
        }
        fun picker(label: String, kind: ChatContentKind, type: String) = action(label).apply {
            setOnClickListener {
                pendingChatChannel = channel
                pendingChatKind = kind
                pendingChatThreadRootId = threadRootId
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
                else -> startChatVoiceRecording(active, channel, status, voice, threadRootId)
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
                    if (chatRecorder == null) startChatVoiceRecording(active, channel, status, voice, threadRootId)
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
        val attachmentActions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val attachmentToggle = action("Add attachment").apply {
            contentDescription = "Add a file or video"
            setOnClickListener {
                val showing = attachmentRow.visibility == View.VISIBLE
                attachmentRow.visibility = if (showing) View.GONE else View.VISIBLE
                text = if (showing) "Add attachment" else "Hide attachments"
            }
        }
        attachmentActions.addView(attachmentToggle, LinearLayout.LayoutParams(0, -2, 1f))
        attachmentActions.addView(voice, LinearLayout.LayoutParams(0, -2, 1f))
        content.addView(attachmentActions)
        content.addView(attachmentRow)
        if (effectiveWorkspace != ChatWorkspace.MESSAGES) {
            composerContext.visibility = View.GONE
            mentionScroll.visibility = View.GONE
            composerRow.visibility = View.GONE
            attachmentActions.visibility = View.GONE
            attachmentRow.visibility = View.GONE
        }
        if (effectiveWorkspace == ChatWorkspace.MESSAGES && chatRecorder != null) {
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
                        showChat(
                            active, channel,
                            if (chatRecorderPaused) "Voice message paused." else "Recording voice message…",
                            threadRootId = chatVoiceThreadRootId,
                        )
                    }.onFailure { status.text = "Could not change the voice recorder state." }
                }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            recorderControls.addView(action("Discard recording").apply {
                setOnClickListener { discardChatVoice(active, channel) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
            content.addView(recorderControls)
        } else if (effectiveWorkspace == ChatWorkspace.MESSAGES && chatPendingVoiceFile != null) {
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
            }, LinearLayout.LayoutParams(-1, dp(44)))
            content.addView(body("Voice message ready · ${chatPendingVoiceDurationMs / 1_000}s"))
        }
        val root = appScreen(content, active, "home", channel)
        setContentView(root)

        var currentConversation: List<ChatConversationMessage> = emptyList()
        var currentChannelDevices: List<ChannelDevice> = emptyList()
        fun renderConversation() {
            val query = search.text.toString().trim()
            rows.removeAllViews()
            if (effectiveWorkspace == ChatWorkspace.MEMBERS) {
                currentChannelDevices.groupBy { it.aci.lowercase() }.forEach { (aci, devices) ->
                    val profile = devices.first().displayName.trim()
                    val name = if (aci == active.aci.lowercase()) "You" else profile.ifBlank { "Encrypted teammate" }
                    rows.addView(action("$name\n${devices.size} device${if (devices.size == 1) "" else "s"} · ${devices.first().role}"))
                }
                if (currentChannelDevices.isEmpty()) rows.addView(body("Loading encrypted participants…"))
                return
            }
            if (effectiveWorkspace == ChatWorkspace.SECURITY) {
                val security = card()
                security.addView(sectionTitle("End-to-end encrypted", "SECURITY"))
                security.addView(body("Membership key epoch ${channel.membershipEpoch}"))
                security.addView(body("Retention: ${channel.retentionDays} days"))
                security.addView(body("Your role: ${channel.role}"))
                security.addView(body("Posting: ${if (channel.isAnnouncement) "announcements only" else "all members"}"))
                security.addView(body("Messages, files, voice notes, and video are encrypted on the sender's device. Server operators cannot read their contents."))
                rows.addView(security)
                return
            }
            val workspaceMessages = when (effectiveWorkspace) {
                ChatWorkspace.MESSAGES -> if (threadRootId == null) {
                    ChatThreads.timeline(currentConversation)
                } else {
                    ChatThreads.thread(threadRootId, currentConversation)
                }
                ChatWorkspace.MEDIA -> currentConversation.filter {
                    it.message.kind != ChatContentKind.TEXT && !it.isDeleted
                }
                ChatWorkspace.BRIEF -> currentConversation.filter { it.isPinned && !it.isDeleted }
                ChatWorkspace.MEMBERS, ChatWorkspace.SECURITY -> emptyList()
            }
            val searchableMessages = if (
                query.isNotEmpty() && threadRootId == null && effectiveWorkspace == ChatWorkspace.MESSAGES
            ) currentConversation else workspaceMessages
            val visible = if (query.isEmpty()) workspaceMessages else searchableMessages.filter {
                ChatMentions.rendered(it.displayText).contains(query, ignoreCase = true) ||
                    (it.message.attachment?.fileName?.contains(query, ignoreCase = true) == true)
            }
            if (visible.isEmpty()) {
                rows.addView(body(when (effectiveWorkspace) {
                    ChatWorkspace.MESSAGES -> "No messages yet. Start the conversation securely."
                    ChatWorkspace.MEDIA -> "No shared files, voice messages, or videos yet."
                    ChatWorkspace.BRIEF -> "Pin important messages to build this channel brief."
                    ChatWorkspace.MEMBERS -> "No active participants."
                    ChatWorkspace.SECURITY -> "Security details unavailable."
                }))
            }
            visible.forEach { item ->
                rows.addView(chatMessageView(
                    active, channel, item, status, composer, composerContext,
                    currentConversation, threadRootId,
                ))
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
                    val readableMessages = if (threadRootId == null) {
                        ChatThreads.timeline(conversation)
                    } else {
                        ChatThreads.thread(threadRootId, conversation)
                    }
                    readableMessages.filter { it.isUnread }.forEach {
                        runCatching { client.sendReceipt(ChatEventKind.READ, it.message.messageId, channel) }
                    }
                    if (readableMessages.any { it.isUnread }) conversation = client.conversation(channel.channelId)
                    ChatRefreshSnapshot(
                        conversation = conversation,
                        pending = client.pendingSendCount(),
                        devices = if (effectiveWorkspace == ChatWorkspace.MEMBERS) {
                            api.channelDevices(active, channel.channelId)
                        } else emptyList(),
                        typing = client.typingParticipants(channel.channelId, threadRootId),
                    )
                }
                runOnUiThread {
                    if (!root.isAttachedToWindow) return@runOnUiThread
                    result.fold(
                        onSuccess = { snapshot ->
                            currentConversation = snapshot.conversation
                            currentChannelDevices = snapshot.devices
                            typingIndicator.text = when (snapshot.typing.size) {
                                0 -> ""
                                1 -> "Someone is typing…"
                                else -> "${snapshot.typing.size} people are typing…"
                            }
                            typingIndicator.visibility = if (snapshot.typing.isEmpty()) View.GONE else View.VISIBLE
                            status.text = initialStatus ?: when {
                                snapshot.pending > 0 -> "${snapshot.pending} message${if (snapshot.pending == 1) "" else "s"} waiting for a connection."
                                snapshot.conversation.isEmpty() -> "No messages yet. Start the conversation securely."
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
        conversation: List<ChatConversationMessage>,
        openThreadRootId: UUID?,
    ): View {
        val message = item.message
        val mine = message.senderAci.equals(active.aci, ignoreCase = true)
        val callTimeline = callTimelineLabel(item.displayText)
        val threadRootId = ChatThreads.rootId(item, conversation)
        val threadReplies = ChatThreads.replies(threadRootId, conversation)
        val reply = item.replyToMessageId?.let { parentId ->
            conversation.firstOrNull { it.message.messageId == parentId }
        }
        val bubble = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(if (mine) colorAccent() else colorSurfaceRaised(), 18f)
            setPadding(dp(13), dp(10), dp(13), dp(10))
        }
        if (item.replyToMessageId != null) bubble.addView(TextView(this).apply {
            val context = reply?.displayText?.ifBlank { reply.message.attachment?.fileName.orEmpty() }
                ?.take(96).orEmpty()
            text = if (context.isEmpty()) "↩ Reply" else "↩ $context"
            textSize = 12f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (mine) 0xddffffff.toInt() else colorAccent())
        })
        message.attachment?.thumbnail?.takeIf { !item.isDeleted }?.let { thumbnail ->
            val width = dp(280)
            val height = (width * thumbnail.height.toFloat() / thumbnail.width.toFloat())
                .toInt().coerceIn(dp(110), dp(220))
            val preview = FrameLayout(this).apply {
                background = rounded(0x22000000, 12f)
                contentDescription = "Encrypted preview for ${message.attachment.fileName}"
            }
            val image = ImageView(this).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            preview.addView(image, FrameLayout.LayoutParams(-1, -1))
            val progress = ProgressBar(this).apply { isIndeterminate = true }
            preview.addView(progress, FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER))
            bubble.addView(preview, LinearLayout.LayoutParams(width, height).apply {
                bottomMargin = dp(8)
            })
            chatThumbnailBitmaps.get(message.messageId)?.let { cached ->
                image.setImageBitmap(cached)
                progress.visibility = View.GONE
            } ?: thread(name = "ptt-chat-thumbnail") {
                val result = runCatching {
                    val bytes = EncryptedChatClient(this, active).thumbnailData(message)
                    requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
                }
                runOnUiThread {
                    if (!preview.isAttachedToWindow) return@runOnUiThread
                    progress.visibility = View.GONE
                    result.fold(
                        onSuccess = { bitmap ->
                            chatThumbnailBitmaps.put(message.messageId, bitmap)
                            image.setImageBitmap(bitmap)
                        },
                        onFailure = {
                            preview.addView(TextView(this).apply {
                                text = "Preview unavailable · tap to open"
                                textSize = 12f
                                gravity = Gravity.CENTER
                                setTextColor(if (mine) Color.WHITE else colorMuted())
                            }, FrameLayout.LayoutParams(-1, -1))
                        },
                    )
                }
            }
        }
        val label = if (item.isDeleted) "Message deleted" else when (message.kind) {
            ChatContentKind.TEXT -> callTimeline ?: item.displayText
            ChatContentKind.VOICE -> "▶  ${message.attachment?.fileName ?: "Voice message"}"
            ChatContentKind.VIDEO -> "▶  ${message.attachment?.fileName ?: "Video"}"
            ChatContentKind.FILE -> "Open  ${message.attachment?.fileName ?: "File"}"
        }
        bubble.contentDescription = buildString {
            append(if (mine) "Your message. " else "Encrypted teammate message. ")
            append(ChatMentions.rendered(label))
            if (!item.isDeleted && message.kind != ChatContentKind.TEXT && item.displayText.isNotBlank()) {
                append(". ")
                append(ChatMentions.rendered(item.displayText))
            }
            append(". Long press for message actions.")
        }
        bubble.addView(TextView(this).apply {
            text = if (!item.isDeleted && message.kind == ChatContentKind.TEXT && callTimeline == null) {
                mentionText(item.displayText, if (mine) Color.WHITE else colorAccent())
            } else label
            textSize = 16f
            setTextColor(if (mine) Color.WHITE else colorText())
            if (item.isDeleted) setTypeface(typeface, Typeface.ITALIC)
            contentDescription = ChatMentions.rendered(label)
        })
        if (!item.isDeleted && message.kind != ChatContentKind.TEXT && item.displayText.isNotBlank()) {
            bubble.addView(TextView(this).apply {
                text = mentionText(item.displayText, if (mine) Color.WHITE else colorAccent())
                textSize = 16f
                setTextColor(if (mine) Color.WHITE else colorText())
                contentDescription = ChatMentions.rendered(item.displayText)
            })
        }
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
            bubble.addView(progress, LinearLayout.LayoutParams(-1, dp(44)))
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
        if (openThreadRootId == null && callTimeline == null && !item.isDeleted && threadReplies.isNotEmpty()) {
            bubble.addView(action("${threadReplies.size} ${if (threadReplies.size == 1) "reply" else "replies"}  ›").apply {
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                contentDescription = "Open thread with ${threadReplies.size} ${if (threadReplies.size == 1) "reply" else "replies"}"
                setTextColor(if (mine) Color.WHITE else colorAccent())
                setOnClickListener {
                    chatEditing = null
                    chatReplyTo = null
                    showChat(active, channel, threadRootId = threadRootId)
                }
            })
        }
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
            chatTransferCancelled.set(false)
            chatCancelTransferButton?.visibility = View.VISIBLE
            thread(name = "ptt-chat-attachment-open") {
                val result = runCatching {
                    val bytes = EncryptedChatClient(this, active).attachmentData(
                        message, onProgress = { progress -> showChatTransferProgress(progress) },
                        isCancelled = chatTransferCancelled::get,
                    )
                    val file = ChatAttachmentProvider.write(this, message.messageId.toString(), message.attachment.fileName, bytes)
                    val uri = ChatAttachmentProvider.uri(this, file)
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, message.attachment.mimeType)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
                runOnUiThread {
                    chatCancelTransferButton?.visibility = View.GONE
                    result.fold(
                        onSuccess = { intent -> startActivity(intent) },
                        onFailure = { status.text = safeMessage(it) },
                    )
                }
            }
        }
        if (!item.isDeleted && callTimeline == null) bubble.setOnLongClickListener {
            val choices = buildList {
                add("Reply in thread")
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
                    "Reply in thread" -> {
                        chatEditing = null
                        chatReplyTo = threadRootId
                        showChat(active, channel, threadRootId = threadRootId)
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
                        val value = ChatMentions.rendered(item.displayText)
                            .ifBlank { message.attachment?.fileName.orEmpty() }
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
                            } else safeMessage(result.exceptionOrNull()!!), threadRootId = openThreadRootId)
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
                        } else safeMessage(result.exceptionOrNull()!!), threadRootId = openThreadRootId)
                    }
                    "Info" -> AlertDialog.Builder(this)
                        .setTitle("Message information")
                        .setMessage(chatMessageInformation(active, item))
                        .setPositiveButton("Done", null)
                        .show()
                    "Delete" -> thread(name = "ptt-chat-delete") {
                        val result = runCatching { EncryptedChatClient(this, active).deleteMessage(message.messageId, channel) }
                        runOnUiThread {
                            showChat(
                                active, channel,
                                if (result.isSuccess) "Message deleted." else safeMessage(result.exceptionOrNull()!!),
                                threadRootId = openThreadRootId,
                            )
                        }
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
                                runOnUiThread {
                                    showChat(
                                        active, channel,
                                        if (result.isSuccess) "Reaction updated." else safeMessage(result.exceptionOrNull()!!),
                                        threadRootId = openThreadRootId,
                                    )
                                }
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

    private fun mentionText(value: String, mentionColor: Int): CharSequence {
        val output = SpannableStringBuilder()
        ChatMentions.segments(value).forEach { segment ->
            val start = output.length
            output.append(segment.text)
            if (segment.isMention) {
                output.setSpan(StyleSpan(Typeface.BOLD), start, output.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
                output.setSpan(ForegroundColorSpan(mentionColor), start, output.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        return output
    }

    private fun shareChatMessage(active: DeviceSession, item: ChatConversationMessage, status: TextView) {
        val message = item.message
        if (message.attachment == null) {
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, ChatMentions.rendered(item.displayText))
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
                                            val thumbnailData = attachment.thumbnail?.let {
                                                runCatching { client.thumbnailData(item.message) }.getOrNull()
                                            }
                                            client.sendAttachment(
                                                client.attachmentData(item.message),
                                                attachment.fileName,
                                                attachment.mimeType,
                                                item.message.kind,
                                                durationMs = attachment.durationMs,
                                                waveform = attachment.waveform,
                                                thumbnailData = thumbnailData,
                                                thumbnailMimeType = attachment.thumbnail?.mimeType ?: "image/jpeg",
                                                thumbnailWidth = attachment.thumbnail?.width ?: 0,
                                                thumbnailHeight = attachment.thumbnail?.height ?: 0,
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

    private fun startChatVoiceRecording(
        active: DeviceSession,
        channel: ChannelSummary,
        status: TextView,
        button: Button,
        threadRootId: UUID?,
    ) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            status.text = "Allow microphone access from the Talk screen first."
            return
        }
        runCatching {
            chatPendingVoiceFile?.delete()
            chatPendingVoiceFile = null
            chatPendingVoiceDurationMs = 0
            chatPendingVoiceWaveform = byteArrayOf()
            chatVoiceThreadRootId = threadRootId
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
            showChat(active, channel, "Voice message was too short.", threadRootId = chatVoiceThreadRootId)
            return
        }
        chatPendingVoiceFile = file
        chatPendingVoiceDurationMs = duration
        chatPendingVoiceWaveform = waveform
        showChat(active, channel, "Voice message ready. Preview, send, or discard it.", threadRootId = chatVoiceThreadRootId)
    }

    private fun sendPendingChatVoice(active: DeviceSession, channel: ChannelSummary) {
        val file = chatPendingVoiceFile ?: return
        val duration = chatPendingVoiceDurationMs
        val waveform = chatPendingVoiceWaveform.copyOf()
        val threadRootId = chatVoiceThreadRootId
        chatPendingVoiceFile = null
        chatPendingVoiceDurationMs = 0
        chatPendingVoiceWaveform = byteArrayOf()
        chatVoiceThreadRootId = null
        chatTransferCancelled.set(false)
        chatTransferStatusView?.text = "Encrypting voice message…"
        chatCancelTransferButton?.visibility = View.VISIBLE
        thread(name = "ptt-chat-voice-send") {
            val result = runCatching {
                EncryptedChatClient(this, active).sendAttachment(
                    file.readBytes(), "Voice message.m4a", "audio/mp4", ChatContentKind.VOICE,
                    durationMs = duration, waveform = waveform, channel = channel,
                    replyTo = threadRootId,
                    onProgress = { progress -> showChatTransferProgress(progress) },
                    isCancelled = chatTransferCancelled::get,
                )
            }
            file.delete()
            runOnUiThread {
                chatCancelTransferButton?.visibility = View.GONE
                result.fold(
                    onSuccess = { showChat(active, channel, "Voice message sent securely.", threadRootId = threadRootId) },
                    onFailure = {
                        val queued = runCatching { EncryptedChatClient(this, active).pendingSendCount() }.getOrDefault(0) > 0
                        showChat(
                            active, channel,
                            if (queued) "Voice message queued. It will send when connected." else safeMessage(it),
                            threadRootId = threadRootId,
                        )
                    },
                )
            }
        }
    }

    private fun showChatTransferProgress(progress: ChatTransferProgress) {
        val percent = if (progress.totalBytes <= 0) 0 else
            ((progress.completedBytes * 100) / progress.totalBytes).coerceIn(0, 100).toInt()
        runOnUiThread {
            chatTransferStatusView?.text = "Sending encrypted attachment… $percent%"
            chatCancelTransferButton?.apply {
                visibility = View.VISIBLE
                isEnabled = true
            }
        }
    }

    private fun discardChatVoice(active: DeviceSession, channel: ChannelSummary) {
        val threadRootId = chatVoiceThreadRootId
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
        chatVoiceThreadRootId = null
        showChat(active, channel, "Voice message discarded.", threadRootId = threadRootId)
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
        button.text = talkButtonLabel("Requesting floor…", "Wait")
        status.text = "Waiting for an authenticated floor grant…"
        PttSessionService.beginTransmit(this, channel)
    }

    private fun endTalk(button: Button, status: TextView) {
        if (!talkPressed) return
        talkPressed = false
        button.text = talkButtonLabel("Hold to talk", "Hold")
        status.setTextColor(colorMuted())
        status.text = "Releasing floor…"
        tones.released()
        PttSessionService.endTransmit(this)
    }

    private fun talkButtonLabel(standard: String, compact: String): String =
        if (talkButtonCompact) compact else standard

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
                "SERVER_UPGRADE_REQUIRED", "SERVER_CAPABILITY_REQUIRED" ->
                    "This team server must be upgraded before this version of PTT Talk can connect securely."
                "CLIENT_UPGRADE_REQUIRED" ->
                    "Update PTT Talk before reconnecting to this team server."
                "SERVER_COMPATIBILITY_UNAVAILABLE" ->
                    "Could not verify that this team server supports the required secure protocol."
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
            PttSessionService.arm(this, selectedChannel)
            armButton?.text = "Disconnect background session"
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

    private fun appScreen(
        content: LinearLayout,
        active: DeviceSession,
        selected: String,
        channel: ChannelSummary? = selectedChannel,
    ): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(colorBackground())
        addView(
            scroll(content),
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )
        val call = CallSessionService.snapshot()
        if (!call.active && selected != "radio") {
            addView(compactPttAccessory(active, channel), LinearLayout.LayoutParams(-1, -2).apply {
                setMargins(dp(12), dp(5), dp(12), dp(5))
            })
        }
        if (call.active && selected != "calls") {
            addView(action(if (call.incoming) "Encrypted call ringing · Open" else "Encrypted call in progress · Return").apply {
                contentDescription = "Return to encrypted call"
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                setOnClickListener { showCalls(active) }
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, -2).apply {
                setMargins(dp(12), dp(4), dp(12), dp(4))
            })
        }
        addView(bottomNavigation(active, selected, channel))
    }

    private fun compactPttAccessory(active: DeviceSession, channel: ChannelSummary?): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            background = rounded(colorSurface(), 32f, colorBorder(), 1)
            elevation = dp(5).toFloat()

            if (channel != null && selectedChannel?.channelId != channel.channelId) {
                selectedChannel = channel
                if (PttSessionService.isArmed(this@TalkActivity)) {
                    PttSessionService.prepare(this@TalkActivity, channel)
                }
            }
            val current = selectedChannel
            val ready = current != null && PttSessionService.isArmed(this@TalkActivity)
            val summary = action(buildString {
                append(current?.displayName ?: "Choose a PTT channel")
                append("\n")
                append(if (ready) "PTT ready · hold to speak" else "Open push-to-talk to connect")
            }).apply {
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
                textSize = 13f
                contentDescription = "Open push-to-talk controls for ${current?.displayName ?: "no selected channel"}"
                setOnClickListener { showTalkConsole(active) }
            }
            compactPttSummaryView = summary
            addView(summary, LinearLayout.LayoutParams(0, dp(62), 1f).apply {
                setMargins(0, 0, dp(10), 0)
            })

            val liveStatus = body(if (ready) "Ready" else "Not connected")
            val hold = primaryAction("Hold").apply {
                textSize = 12f
                minWidth = dp(52)
                minHeight = dp(52)
                isEnabled = ready && current?.role != "listen"
                contentDescription = "Hold to talk"
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(colorAccent())
                }
                setOnTouchListener { _, event ->
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            beginTalk(this, liveStatus)
                            true
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            endTalk(this, liveStatus)
                            true
                        }
                        else -> false
                    }
                }
            }
            talkButtonCompact = true
            talkButton = hold
            talkStatusView = liveStatus
            addView(hold, LinearLayout.LayoutParams(dp(52), dp(52)))
        }

    private fun refreshCompactPttSummary() {
        val current = selectedChannel
        val ready = current != null && PttSessionService.isArmed(this) && !CallSessionService.isActive()
        compactPttSummaryView?.apply {
            text = buildString {
                append(current?.displayName ?: "Choose a PTT channel")
                append("\n")
                append(if (ready) "PTT ready · hold to speak" else "Open push-to-talk to connect")
            }
            contentDescription = "Open push-to-talk controls for ${current?.displayName ?: "no selected channel"}"
        }
    }

    private fun bottomNavigation(
        active: DeviceSession,
        selected: String,
        channel: ChannelSummary?,
    ): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        setPadding(dp(8), dp(7), dp(8), dp(10))
        background = rounded(colorSurface(), 0f, colorBorder(), 1)

        fun destination(id: String, label: String, onClick: () -> Unit): Button = Button(this@TalkActivity).apply {
            text = label
            isAllCaps = false
            textSize = 12f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            minHeight = dp(52)
            stateListAnimator = null
            elevation = 0f
            setTextColor(if (id == selected) colorAccent() else colorMuted())
            background = if (id == selected) rounded(withAlpha(colorAccent(), 28), 18f) else rounded(Color.TRANSPARENT, 18f)
            contentDescription = if (id == selected) "$label, selected" else label
            setOnClickListener { onClick() }
        }

        addView(destination("home", "Chats") { showTalkHome(active) }, LinearLayout.LayoutParams(0, -2, 1f))
        addView(destination("calls", "Calls") {
            showCalls(active)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        addView(destination("activity", "Activity") {
            (selectedChannel ?: channel)?.let { showHistory(active, it) } ?: showTalkHome(active)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        addView(destination("you", "Settings") { showAccountSettings(active) }, LinearLayout.LayoutParams(0, -2, 1f))
    }

    private fun showCalls(active: DeviceSession, initialStatus: String? = null, missedOnly: Boolean = false) {
        val content = column()
        content.addView(sectionTitle("Calls", "END-TO-END ENCRYPTED"))
        content.addView(versionLabel())
        initialStatus?.let { content.addView(statusPill(it)) }

        val snapshot = CallSessionService.snapshot()
        if (snapshot.active) {
            val activeCard = card()
            activeCard.addView(sectionTitle(
                if (snapshot.incoming) "Incoming call" else "Active call",
                snapshot.status.ifBlank { "SECURING CALL" }.uppercase(),
            ))
            activeCard.addView(body("Media stays blocked until every joined device completes the encrypted key exchange."))
            activeCard.addView(statusPill("Connection · ${snapshot.connectionQuality}"))
            if (snapshot.activeSpeakerAcis.isNotEmpty()) {
                activeCard.addView(body("Speaking now · ${snapshot.activeSpeakerAcis.size} participant${if (snapshot.activeSpeakerAcis.size == 1) "" else "s"}"))
            }
            val controls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            if (snapshot.incoming) {
                controls.addView(primaryAction("Answer").apply {
                    contentDescription = "Answer encrypted call"
                    setOnClickListener {
                        CallSessionService.answer(this@TalkActivity)
                        mainHandler.postDelayed({ showCalls(active) }, 500)
                    }
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(0, 0, dp(4), 0) })
            }
            if (!snapshot.incoming) {
                controls.addView(action(if (snapshot.muted) "Unmute" else "Mute").apply {
                    contentDescription = if (snapshot.muted) "Unmute microphone" else "Mute microphone"
                    setOnClickListener {
                        CallSessionService.setMuted(this@TalkActivity, !snapshot.muted)
                        mainHandler.postDelayed({ showCalls(active) }, 250)
                    }
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, dp(4), 0) })
            }
            controls.addView(dangerAction(if (snapshot.incoming) "Decline" else "End").apply {
                contentDescription = if (snapshot.incoming) "Decline encrypted call" else "End encrypted call"
                setOnClickListener {
                    if (snapshot.incoming) CallSessionService.decline(this@TalkActivity)
                    else CallSessionService.end(this@TalkActivity)
                    mainHandler.postDelayed({ showCalls(active, "Call ended.") }, 500)
                }
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, 0, 0) })
            activeCard.addView(controls)
            activeCard.addView(action("Audio · ${snapshot.routeName}").apply {
                contentDescription = "Choose call audio route. Current route ${snapshot.routeName}"
                isEnabled = snapshot.routes.isNotEmpty()
                setOnClickListener {
                    AlertDialog.Builder(this@TalkActivity)
                        .setTitle("Call audio")
                        .setItems(snapshot.routes.map { it.name }.toTypedArray()) { _, index ->
                            CallSessionService.selectRoute(this@TalkActivity, snapshot.routes[index].id)
                            mainHandler.postDelayed({ showCalls(active) }, 350)
                        }
                        .setNegativeButton("Cancel", null)
                        .show()
                }
            })
            activeCard.addView(action("Participants & add people").apply {
                contentDescription = "View and manage encrypted call participants"
                setOnClickListener { showCallParticipants(active, requireNotNull(snapshot.callId)) }
            })
            addCard(content, activeCard)
        }

        val readiness = card()
        readiness.addView(sectionTitle("Secure calling", "MEDIA READINESS"))
        val readinessStatus = statusPill("Checking your team call service…")
        readiness.addView(readinessStatus)
        addCard(content, readiness)

        val recent = card()
        recent.addView(sectionTitle("Recent calls", "ALL · MISSED"))
        val historyFilter = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        historyFilter.addView(action("All").apply {
            isEnabled = missedOnly
            setOnClickListener { showCalls(active, missedOnly = false) }
        }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(0, 0, dp(4), 0) })
        historyFilter.addView(action("Missed").apply {
            isEnabled = !missedOnly
            setOnClickListener { showCalls(active, missedOnly = true) }
        }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, 0, 0) })
        recent.addView(historyFilter)
        val recentRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        recentRows.addView(body("Loading encrypted call history…"))
        recent.addView(recentRows)
        addCard(content, recent)

        val conversations = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(conversations)
        val root = appScreen(content, active, "calls")
        setContentView(root)

        thread(name = "ptt-calls-dashboard") {
            val result = runCatching {
                val api = ControlApi(active.serverUrl)
                val channels = api.channels(active)
                val chat = EncryptedChatClient(this@TalkActivity, active)
                runCatching { chat.poll(channels) }
                Triple(api.callCapabilities(active), channels, chat.callHistory(channels))
            }
            runOnUiThread {
                if (!root.isAttachedToWindow) return@runOnUiThread
                result.fold(
                    onSuccess = { (capabilities, channels, history) ->
                        val ready = capabilities.enabled && capabilities.mediaReady && capabilities.protocolMajor == 1
                        readinessStatus.setTextColor(if (ready) colorSuccess() else colorDanger())
                        readinessStatus.text = when {
                            !capabilities.enabled -> "Encrypted calls are disabled by this team administrator."
                            !capabilities.mediaReady -> "The private media node is not ready. Calls remain safely unavailable."
                            capabilities.protocolMajor != 1 -> "This app and team server need compatible call-protocol versions."
                            else -> "Ready for encrypted calls with up to ${capabilities.maximumParticipants} people."
                        }
                        recentRows.removeAllViews()
                        val visibleHistory = history.filter { !missedOnly || it.missed }
                        if (visibleHistory.isEmpty()) {
                            recentRows.addView(body(if (missedOnly) {
                                "No missed calls."
                            } else {
                                "Encrypted call events will appear here after your first call. No call audio is recorded."
                            }))
                        } else {
                            visibleHistory.forEach { item ->
                                val channel = channels.firstOrNull {
                                    it.channelId.equals(item.channelId.toString(), true)
                                }
                                val direction = when {
                                    item.missed -> "Missed"
                                    item.outgoing -> "Outgoing"
                                    else -> "Incoming"
                                }
                                val seconds = item.durationMs / 1_000
                                val duration = if (seconds > 0) " · ${seconds / 60}m ${seconds % 60}s" else ""
                                recentRows.addView(action(
                                    "${channel?.displayName ?: "Private call"}\n$direction · ${item.participantCount} participant${if (item.participantCount == 1) "" else "s"}$duration",
                                ).apply {
                                    gravity = Gravity.START or Gravity.CENTER_VERTICAL
                                    minHeight = dp(64)
                                    contentDescription = "$direction call with ${channel?.displayName ?: "private conversation"}. Call back."
                                    isEnabled = ready && !snapshot.active && channel != null
                                    setOnClickListener { channel?.let { confirmAndStartCall(active, it) } }
                                })
                            }
                        }
                        val start = card()
                        start.addView(sectionTitle("Start a call", "CONVERSATIONS"))
                        if (!ready) {
                            start.addView(body("Calling will appear automatically after the media readiness check passes."))
                        } else if (channels.isEmpty()) {
                            start.addView(body("Create a conversation or ask an administrator to add you to a channel first."))
                        } else {
                            channels.forEach { channel ->
                                start.addView(action("${channel.displayName}\n${if (channel.kind == "direct") "Private call" else "Group call"}").apply {
                                    gravity = Gravity.START or Gravity.CENTER_VERTICAL
                                    minHeight = dp(64)
                                    isEnabled = !snapshot.active
                                    setOnClickListener { confirmAndStartCall(active, channel) }
                                })
                            }
                        }
                        addCard(conversations, start)
                    },
                    onFailure = {
                        readinessStatus.setTextColor(colorDanger())
                        readinessStatus.text = safeMessage(it)
                    },
                )
            }
        }
    }

    private fun confirmAndStartCall(active: DeviceSession, channel: ChannelSummary) {
        if (CallSessionService.isActive()) {
            showCalls(active, "Finish the current call before starting another one.")
            return
        }
        val waiting = AlertDialog.Builder(this)
            .setTitle("Preparing encrypted call")
            .setMessage("Checking eligible participants…")
            .setNegativeButton("Cancel", null)
            .show()
        thread(name = "ptt-call-participants") {
            val result = runCatching {
                val api = ControlApi(active.serverUrl)
                val capabilities = api.callCapabilities(active)
                require(capabilities.enabled && capabilities.mediaReady) { "The private call media service is not ready." }
                api.channelDevices(active, channel.channelId)
                    .asSequence()
                    .filter { !it.aci.equals(active.aci, true) }
                    .distinctBy { it.aci.lowercase() }
                    .take(capabilities.maximumParticipants.coerceAtMost(8) - 1)
                    .toList()
            }
            runOnUiThread {
                waiting.dismiss()
                result.fold(
                    onSuccess = { members ->
                        if (members.isEmpty()) {
                            showCalls(active, "No eligible teammate is currently in ${channel.displayName}.")
                            return@fold
                        }
                        val selected = BooleanArray(members.size) { channel.kind == "direct" || members.size == 1 }
                        val dialog = AlertDialog.Builder(this)
                            .setTitle("Call ${channel.displayName}?")
                            .setMessage("Choose up to seven people. Both linked devices may ring; the first answer claims each person's seat.")
                            .setMultiChoiceItems(members.map { it.displayName }.toTypedArray(), selected) { choice, index, checked ->
                                if (checked && selected.count { it } > 7) {
                                    selected[index] = false
                                    (choice as AlertDialog).listView.setItemChecked(index, false)
                                }
                            }
                            .setNegativeButton("Cancel", null)
                            .setPositiveButton("Call", null)
                            .create()
                        dialog.setOnShowListener {
                            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                                val invitees = members.filterIndexed { index, _ -> selected[index] }.map { it.aci }
                                if (invitees.isEmpty()) {
                                    dialog.listView.announceForAccessibility("Choose at least one teammate")
                                    return@setOnClickListener
                                }
                                dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
                                thread(name = "ptt-start-call") {
                                    val started = runCatching {
                                        val call = ControlApi(active.serverUrl).startCall(active, channel.channelId, invitees)
                                        call
                                    }
                                    runOnUiThread {
                                        dialog.dismiss()
                                        started.fold(
                                            onSuccess = {
                                                CallSessionService.outgoing(this@TalkActivity, it.callId)
                                                showCalls(active, "Calling ${channel.displayName} securely…")
                                            },
                                            onFailure = { showCalls(active, safeMessage(it)) },
                                        )
                                    }
                                }
                            }
                        }
                        dialog.show()
                    },
                    onFailure = { showCalls(active, safeMessage(it)) },
                )
            }
        }
    }

    private fun showCallParticipants(active: DeviceSession, callId: String) {
        val waiting = AlertDialog.Builder(this)
            .setTitle("Call participants")
            .setMessage("Loading the authorized roster…")
            .setNegativeButton("Cancel", null)
            .show()
        thread(name = "ptt-call-roster") {
            val result = runCatching {
                val api = ControlApi(active.serverUrl)
                val call = api.call(active, callId)
                val channels = api.channels(active)
                Triple(call, channels.firstOrNull { it.channelId.equals(call.conversationId, true) }, api.directory(active))
            }
            runOnUiThread {
                waiting.dismiss()
                result.fold(
                    onSuccess = { (call, channel, directory) ->
                        val roster = call.participants.sortedBy { it.joinOrder }
                        val names = directory.associate { it.aci.lowercase() to it.displayName }
                        val rosterText = roster.joinToString("\n") { participant ->
                            "${names[participant.aci.lowercase()] ?: "Encrypted teammate"} · ${participant.state.replace('_', ' ')}"
                        }
                        val dialog = AlertDialog.Builder(this)
                            .setTitle("Call participants")
                            .setMessage(rosterText.ifBlank { "No participants" })
                            .setNegativeButton("Done", null)
                        val available = directory.filter { member ->
                            roster.none { it.aci.equals(member.aci, true) } && !member.aci.equals(active.aci, true)
                        }.take((8 - roster.size).coerceAtLeast(0))
                        if (call.requesterIsHost && available.isNotEmpty()) {
                            dialog.setPositiveButton("Add people") { _, _ ->
                                chooseAdditionalCallParticipants(active, call, channel, available)
                            }
                        }
                        dialog.show()
                    },
                    onFailure = { showCalls(active, safeMessage(it)) },
                )
            }
        }
    }

    private fun chooseAdditionalCallParticipants(
        active: DeviceSession,
        call: CallSessionSummary,
        channel: ChannelSummary?,
        candidates: List<DirectoryMember>,
    ) {
        val selected = BooleanArray(candidates.size)
        val convertsDirect = channel?.kind == "direct"
        val explanation = if (convertsDirect) {
            "Adding someone to a direct call creates a new private group conversation. Earlier messages and media are not shared."
        } else {
            "New participants receive future encrypted call media only."
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(if (convertsDirect) "Create a private group?" else "Add people")
            .setMessage(explanation)
            .setMultiChoiceItems(candidates.map { it.displayName }.toTypedArray(), selected) { choice, index, checked ->
                if (checked && selected.count { it } > 8 - call.participants.size) {
                    selected[index] = false
                    (choice as AlertDialog).listView.setItemChecked(index, false)
                }
            }
            .setNegativeButton("Cancel", null)
            .setPositiveButton(if (convertsDirect) "Create group & add" else "Add", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val chosen = candidates.filterIndexed { index, _ -> selected[index] }
                if (chosen.isEmpty()) return@setOnClickListener
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
                thread(name = "ptt-add-call-participants") {
                    val updated = runCatching {
                        val api = ControlApi(active.serverUrl)
                        val call = api.addCallParticipants(
                            active,
                            call.callId,
                            chosen.map { it.aci },
                            confirmCreatePrivateGroup = convertsDirect,
                            displayName = if (convertsDirect) {
                                (listOfNotNull(channel?.displayName) + chosen.map { it.displayName }).joinToString(", ").take(80)
                            } else "",
                        )
                        call
                    }
                    runOnUiThread {
                        dialog.dismiss()
                        showCalls(active, updated.fold(
                            onSuccess = { "Invitation sent. The call is rotating encryption keys." },
                            onFailure = ::safeMessage,
                        ))
                    }
                }
            }
        }
        dialog.show()
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

    private fun callTimelineLabel(value: String): String? = runCatching {
        EncryptedCallTimelineCodec.decode(value)
    }.getOrNull()?.let { event ->
        when (event.kind) {
            CallTimelineEventKind.STARTED -> "☎ Started an encrypted call"
            CallTimelineEventKind.ANSWERED -> "☎ Answered the encrypted call"
            CallTimelineEventKind.PARTICIPANTS_CHANGED -> "☎ Changed call participants"
            CallTimelineEventKind.ENDED -> if (event.endReason == "sos_preempted") {
                "☎ Call ended for priority SOS"
            } else "☎ Call ended${if (event.durationMs > 0) " · ${event.durationMs / 1_000}s" else ""}"
        }
    }

    private fun savedMessageLabel(item: ChatConversationMessage): String =
        callTimelineLabel(item.displayText) ?: when (item.message.kind) {
            ChatContentKind.TEXT -> ChatMentions.rendered(item.displayText).trim()
            ChatContentKind.VOICE -> item.message.attachment?.durationMs?.let {
                "Voice message · ${it / 1_000}s"
            } ?: "Voice message"
            ChatContentKind.VIDEO -> item.message.attachment?.fileName ?: "Video"
            ChatContentKind.FILE -> item.message.attachment?.fileName ?: "File"
        }

    private fun conversationSearchEntry(item: ChatConversationMessage): ConversationSearchEntry? {
        if (item.isDeleted) return null
        val preview = savedMessageLabel(item)
        val attachmentName = item.message.attachment?.fileName.orEmpty()
        val searchable = "$preview $attachmentName".trim()
        if (searchable.isEmpty()) return null
        return ConversationSearchEntry(item.message.sentAt, searchable, preview)
    }

    private fun threadAttention(
        conversation: List<ChatConversationMessage>,
        localAci: String,
    ): List<ThreadAttentionSummary> =
        ChatThreads.timeline(conversation).mapNotNull { root ->
            val unreadReplies = ChatThreads.replies(root.message.messageId, conversation).filter { it.isUnread }
            val latest = unreadReplies.lastOrNull() ?: return@mapNotNull null
            ThreadAttentionSummary(
                rootId = root.message.messageId,
                unreadCount = unreadReplies.size,
                preview = savedMessageLabel(latest).ifBlank { "Encrypted attachment" },
                lastActivity = latest.message.sentAt,
                hasMention = unreadReplies.any {
                    ChatMentions.containsLocalMention(it.displayText, localAci)
                },
            )
        }

    private fun rootAttentionPreview(conversation: List<ChatConversationMessage>): String =
        ChatThreads.timeline(conversation).lastOrNull { it.isUnread }
            ?.let(::savedMessageLabel)?.ifBlank { "Encrypted attachment" }
            ?: "Unread encrypted message"

    private fun matchingConversationSearchEntry(
        summary: ConversationSummary,
        query: String,
    ): ConversationSearchEntry? = query.takeIf { it.isNotBlank() }?.let { term ->
        summary.searchEntries
            .filter { it.searchableText.contains(term, ignoreCase = true) }
            .maxByOrNull { it.sentAt }
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

    private fun versionLabel(): TextView {
        val displayVersion = BuildConfig.VERSION_NAME.removeSuffix("-debug")
        return body("Version $displayVersion (${BuildConfig.VERSION_CODE})").apply {
            textSize = 12f
            contentDescription = "PTT Talk version $displayVersion, build ${BuildConfig.VERSION_CODE}"
            setPadding(0, 0, 0, dp(8))
        }
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

    private fun colorBackground(): Int = Color.parseColor(if (isDarkTheme()) "#1B1C1E" else "#FFFFFF")
    private fun colorSurface(): Int = Color.parseColor(if (isDarkTheme()) "#242526" else "#FFFFFF")
    private fun colorSurfaceRaised(): Int = Color.parseColor(if (isDarkTheme()) "#303133" else "#F1F1F1")
    private fun colorBorder(): Int = Color.parseColor(if (isDarkTheme()) "#3D3E40" else "#DEDEDE")
    private fun colorText(): Int = Color.parseColor(if (isDarkTheme()) "#F5F5F5" else "#1B1B1B")
    private fun colorMuted(): Int = Color.parseColor(if (isDarkTheme()) "#B7B7B7" else "#5E5E5E")
    private fun colorAccent(): Int = Color.parseColor(if (isDarkTheme()) "#70A5EB" else "#2C6BED")
    private fun colorSuccess(): Int = Color.parseColor(if (isDarkTheme()) "#52C7A5" else "#087F5B")
    private fun colorDanger(): Int = Color.parseColor(if (isDarkTheme()) "#FF6B6B" else "#C83232")

    private fun conversationAvatarColor(seed: String): Int {
        val palette = intArrayOf(
            Color.parseColor("#4A67D6"), Color.parseColor("#087F8C"),
            Color.parseColor("#A34F82"), Color.parseColor("#39745D"),
        )
        return palette[(seed.hashCode() and Int.MAX_VALUE) % palette.size]
    }

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
        const val EXTRA_DEBUG_ALLOW_SCREENSHOTS = "app.ptt.talk.extra.DEBUG_ALLOW_SCREENSHOTS"
        const val PRIVACY_POLICY_URL = "https://ptttalk.app/privacy#deletion"
    }
}
