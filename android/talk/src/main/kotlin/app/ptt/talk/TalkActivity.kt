package app.ptt.talk

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
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
    @Volatile private var busy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val col =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(pad, pad, pad, pad)
                setBackgroundColor(Color.WHITE)
            }
        col.addView(
            TextView(this).apply {
                text = "PTT device harness"
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
        col.addView(actionButton("LISTEN as Bob") { listen() })
        col.addView(actionButton("SEND tone as Alice") { send() })
        log =
            TextView(this).apply {
                typeface = android.graphics.Typeface.MONOSPACE
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTextColor(Color.DKGRAY)
                text = "ready\n"
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
            "bob" -> listen()
            "alice" -> window.decorView.postDelayed({ send() }, 1_500)
        }
    }

    private fun actionButton(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            gravity = Gravity.CENTER
            setOnClickListener { onClick() }
        }

    private fun listen() {
        if (busy) return
        busy = true
        append("listening as Bob…")
        val (pre, host, port) = endpoints()
        thread(name = "ptt-recv") {
            try {
                val out = File(cacheDir, "bob.wav")
                val r =
                    TalkClient(DemoIds.BOB, DemoIds.ALICE, pre, host, port)
                        .recvTone(outWav = out, timeoutMs = 120_000)
                ui("recv frames=${r.frames} energy=${r.energy}\nwav=${out.absolutePath}")
            } catch (t: Throwable) {
                ui("recv error: ${t.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun send() {
        if (busy) return
        busy = true
        append("sending as Alice…")
        val (pre, host, port) = endpoints()
        thread(name = "ptt-send") {
            try {
                val n =
                    TalkClient(DemoIds.ALICE, DemoIds.BOB, pre, host, port)
                        .sendTone(durationMs = 400, paceMs = 5, bindWaitMs = 300)
                ui("sent $n frames")
            } catch (t: Throwable) {
                ui("send error: ${t.message}")
            } finally {
                busy = false
            }
        }
    }

    private fun endpoints(): Triple<String, String, Int> {
        val pre = prekey.text.toString().trim()
        val rel = relay.text.toString().trim()
        val parts = rel.split(":")
        require(parts.size == 2) { "relay must be host:port" }
        return Triple(pre, parts[0], parts[1].toInt())
    }

    private fun append(line: String) {
        Log.i(TAG, line)
        log.append(line + "\n")
    }

    private fun ui(line: String) {
        runOnUiThread { append(line) }
    }

    companion object {
        const val TAG = "PttTalk"
        const val DEFAULT_PREKEY = "http://192.168.1.229:8088"
        const val DEFAULT_RELAY = "192.168.1.229:47000"
    }
}
