package app.ptt.talk

import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

internal data class CallCoordinationEvent(val callId: String, val type: String)

/** Foreground low-latency coordination; FCM remains the wake path. */
internal class CallEventStream(
    private val session: DeviceSession,
    private val onEvent: (CallCoordinationEvent) -> Unit,
) : WebSocketListener(), AutoCloseable {
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "ptt-call-events").apply { isDaemon = true }
    }
    private val client = OkHttpClient.Builder().pingInterval(25, TimeUnit.SECONDS).build()
    @Volatile private var socket: WebSocket? = null
    @Volatile private var closed = false
    private var retrySeconds = 1L
    private var reconnectScheduled = false

    fun start() = connect()

    @Synchronized
    private fun connect() {
        reconnectScheduled = false
        if (closed) return
        val base = session.serverUrl.trimEnd('/')
        val url = when {
            base.startsWith("https://", true) -> "wss://${base.substringAfter("://")}/v1/calls/events"
            base.startsWith("http://", true) && BuildConfig.DEBUG -> "ws://${base.substringAfter("://")}/v1/calls/events"
            else -> return
        }
        socket = client.newWebSocket(
            Request.Builder().url(url).header("Authorization", "Bearer ${session.accessToken}").build(),
            this,
        )
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        retrySeconds = 1
        synchronized(this) { reconnectScheduled = false }
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        runCatching {
            val value = JSONObject(text)
            require(value.optInt("protocolVersion") == 1)
            val callId = UUID.fromString(value.getString("callId")).toString().lowercase()
            val type = value.getString("type")
            require(type in setOf("ringing", "answered", "roster_changed", "ended"))
            CallCoordinationEvent(callId, type)
        }.onSuccess(onEvent)
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = reconnect()
    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = reconnect()

    @Synchronized
    private fun reconnect() {
        if (closed || reconnectScheduled) return
        reconnectScheduled = true
        socket = null
        val delay = retrySeconds
        retrySeconds = (retrySeconds * 2).coerceAtMost(15)
        scheduler.schedule(::connect, delay, TimeUnit.SECONDS)
    }

    override fun close() {
        closed = true
        socket?.close(1000, "APP_STOPPED")
        socket = null
        scheduler.shutdownNow()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}
