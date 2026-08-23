package app.ptt.talk

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowInsets
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import app.ptt.net.DemoIds
import app.ptt.net.TalkClient
import java.io.File
import kotlin.concurrent.thread

/**
 * Device harness, not product Talk UI (PR13). Hold/send still uses the 440 Hz
 * tone until AudioEngine (PR5). Speaks [docs/WIRE.md] through the JVM relay.
 */
class TalkActivity : Activity() {
    private lateinit var prekey: EditText
    private lateinit var relay: EditText
    private lateinit var log: TextView
    private lateinit var encryption: TextView
    private lateinit var listenButton: Button
    private lateinit var sendButton: Button
    @Volatile private var busy = false
    @Volatile private var listening = false
    @Volatile private var listenerRunning = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val col =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(pad, pad, pad, pad)
                setBackgroundColor(Color.WHITE)
                setOnApplyWindowInsetsListener { view, insets ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val bars = insets.getInsets(WindowInsets.Type.systemBars())
                        view.setPadding(pad + bars.left, pad + bars.top, pad + bars.right, pad + bars.bottom)
                    } else {
                        @Suppress("DEPRECATION")
                        view.setPadding(
                            pad + insets.systemWindowInsetLeft,
                            pad + insets.systemWindowInsetTop,
                            pad + insets.systemWindowInsetRight,
                            pad + insets.systemWindowInsetBottom,
                        )
                    }
                    insets
                }
            }
        col.addView(
            TextView(this).apply {
                text = getString(R.string.harness_title)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setTextColor(Color.BLACK)
            }
        )
        prekey =
            EditText(this).apply {
                setText(DEFAULT_PREKEY)
                hint = "prekey URL"
            }
        relay =
            EditText(this).apply {
                setText(DEFAULT_RELAY)
                hint = "relay host:port"
            }
        col.addView(prekey)
        col.addView(relay)
        listenButton = actionButton("LISTEN continuously as Bob") { toggleListening() }
        sendButton = actionButton("SEND tone as Alice") { send() }
        col.addView(listenButton)
        col.addView(sendButton)
        col.addView(
            TextView(this).apply {
                text = "Encryption"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                setTextColor(Color.BLACK)
            },
        )
        encryption =
            TextView(this).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTextColor(Color.DKGRAY)
                text = "No encrypted tone yet."
                setTextIsSelectable(true)
            }
        col.addView(encryption)
        col.addView(
            TextView(this).apply {
                text = "Activity"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                setTextColor(Color.BLACK)
            },
        )
        log =
            TextView(this).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTextColor(Color.DKGRAY)
                text = getString(R.string.ready_log)
            }
        val scroll = ScrollView(this)
        scroll.addView(log)
        col.addView(
            scroll,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )
        setContentView(col)
        intent.getStringExtra("ptt_prekey")?.let { prekey.setText(it) }
        intent.getStringExtra("ptt_relay")?.let { relay.setText(it) }
        when (intent.getStringExtra("ptt_role")) {
            "bob" -> startListening()
            "alice" -> window.decorView.postDelayed({ send() }, 1_500)
        }
    }

    private fun actionButton(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            gravity = Gravity.CENTER
            setOnClickListener { onClick() }
        }

    private fun toggleListening() {
        if (listening) {
            listening = false
            append("stopping listener…")
            updateControls()
        } else {
            startListening()
        }
    }

    private fun startListening() {
        if (busy || listenerRunning) return
        val endpoint = validatedEndpoints("listen") ?: return
        listening = true
        listenerRunning = true
        updateControls()
        val (pre, host, port) = endpoint
        thread(name = "ptt-recv") {
            try {
                var receivedCount = 0
                while (listening) {
                    ui(if (receivedCount == 0) "listening as Bob…" else "listener rearmed")
                    try {
                        val out = File(cacheDir, "bob.wav")
                        val r =
                            TalkClient(DemoIds.BOB, DemoIds.ALICE, pre, host, port)
                                .recvTone(outWav = out, timeoutMs = 120_000) { listening }
                        if (!listening) break
                        if (r.frames == 0) continue

                        receivedCount += 1
                        r.encryption?.let { uiEncryption(formatEncryption(it, "receiver (Bob)")) }
                        ui("recv #$receivedCount frames=${r.frames} energy=${r.energy}\nwav=${out.absolutePath}")
                        try {
                            ui("playing received tone #$receivedCount")
                            ReceivedPcmPlayer.playBlocking(this, r.pcm)
                            ui("playback #$receivedCount complete")
                        } catch (t: Throwable) {
                            ui("playback #$receivedCount error: ${t.message}")
                        }
                    } catch (t: Throwable) {
                        if (!listening) break
                        ui("recv error: ${t.message}\nrearming listener…")
                        Thread.sleep(500)
                    }
                }
            } catch (t: Throwable) {
                if (listening) ui("listener error: ${t.message}")
            } finally {
                listening = false
                listenerRunning = false
                ui("listener stopped")
                runOnUiThread { updateControls() }
            }
        }
    }

    private fun send() {
        if (busy) return
        val endpoint = validatedEndpoints("send") ?: return
        setBusy(true)
        append("sending as Alice…")
        val (pre, host, port) = endpoint
        thread(name = "ptt-send") {
            try {
                val result =
                    TalkClient(DemoIds.ALICE, DemoIds.BOB, pre, host, port)
                        .sendToneDetailed(durationMs = 400, paceMs = 5, bindWaitMs = 300)
                uiEncryption(formatEncryption(result.encryption, "sender (Alice)"))
                ui("sent ${result.frames} encrypted frames")
            } catch (t: Throwable) {
                ui("send error: ${t.message}")
            } finally {
                runOnUiThread { setBusy(false) }
            }
        }
    }

    private fun validatedEndpoints(action: String): Triple<String, String, Int>? =
        try {
            endpoints()
        } catch (t: IllegalArgumentException) {
            append("$action error: ${t.message}")
            null
        }

    private fun endpoints(): Triple<String, String, Int> {
        val pre = prekey.text.toString().trim()
        val rel = relay.text.toString().trim()
        val parts = rel.split(":")
        val port = parts.getOrNull(1)?.toIntOrNull()
        require(pre.startsWith("http://") || pre.startsWith("https://")) { "prekey must be an HTTP(S) URL" }
        require(parts.size == 2 && parts[0].isNotBlank() && port != null && port in 1..65535) {
            "relay must be host:port"
        }
        return Triple(pre, parts[0], port)
    }

    private fun setBusy(value: Boolean) {
        busy = value
        updateControls()
    }

    private fun updateControls() {
        listenButton.text =
            when {
                listenerRunning && listening -> "STOP listening"
                listenerRunning -> "STOPPING listener…"
                else -> "LISTEN continuously as Bob"
            }
        listenButton.isEnabled = !busy && (!listenerRunning || listening)
        sendButton.isEnabled = !busy && !listenerRunning
        prekey.isEnabled = !busy && !listenerRunning
        relay.isEnabled = !busy && !listenerRunning
    }

    override fun onDestroy() {
        listening = false
        super.onDestroy()
    }

    private fun append(line: String) {
        Log.i(TAG, line)
        log.append(line + "\n")
    }

    private fun ui(line: String) {
        runOnUiThread { append(line) }
    }

    private fun uiEncryption(value: String) {
        runOnUiThread { encryption.text = value }
    }

    private fun formatEncryption(value: app.ptt.net.EncryptionDiagnostics, role: String): String =
        listOf(
            "side: $role",
            "key setup: ${value.keyEstablishment}",
            "media: ${value.algorithm}",
            "channel: ${value.channel}",
            "talk: ${value.talkId}",
            "sender: ${value.senderAci}",
            "receiver: ${value.receiverAci}",
            "demux: ${value.demux}  frames: ${value.frameCount}",
            "wrapped key: ${value.wrappedKeyBytes} bytes",
            "key fp: sha256:${value.mediaKeyFingerprint}",
            "AAD fp: sha256:${value.aadFingerprint}",
        ).joinToString("\n")

    companion object {
        const val TAG = "PttTalk"
        const val DEFAULT_PREKEY = "http://192.168.1.229:8088"
        const val DEFAULT_RELAY = "192.168.1.229:47000"
    }
}
