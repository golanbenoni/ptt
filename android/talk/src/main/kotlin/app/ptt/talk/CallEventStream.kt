package app.ptt.talk

import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

internal data class CallCoordinationEvent(val callId: String, val type: String)

internal fun callEventWebSocketUrl(serverUrl: String, allowPlaintext: Boolean): String? {
    val base = serverUrl.trimEnd('/').toHttpUrlOrNull() ?: return null
    val websocketScheme = when (base.scheme.lowercase()) {
        "https" -> "wss"
        "http" -> if (allowPlaintext) "ws" else return null
        else -> return null
    }
    val normalized = base.newBuilder()
        .encodedPath("/v1/calls/events")
        .query(null)
        .fragment(null)
        .build()
        .toString()
    val authorityAndPath = normalized.substringAfter("://")
    return "$websocketScheme://$authorityAndPath"
}

/**
 * Serializes WebSocket ownership independently of OkHttp's callback threads.
 * A delayed callback from a retired connection must never clear or reconnect
 * over the newer healthy stream.
 */
internal class CallEventConnectionState<T : Any> {
    private var active: T? = null
    private var closed = false
    private var connecting = false
    private var reconnectScheduled = false
    private var retrySeconds = 1L

    @Synchronized
    fun beginConnect(): Boolean {
        if (closed || connecting || active != null) return false
        connecting = true
        reconnectScheduled = false
        return true
    }

    @Synchronized
    fun attach(connection: T): Boolean {
        connecting = false
        if (closed) return false
        active = connection
        return true
    }

    @Synchronized
    fun opened(connection: T): Boolean {
        if (closed || active !== connection) return false
        retrySeconds = 1
        reconnectScheduled = false
        return true
    }

    @Synchronized
    fun accepts(connection: T): Boolean = !closed && active === connection

    @Synchronized
    fun reconnectDelay(connection: T): Long? {
        if (closed || reconnectScheduled || active !== connection) return null
        active = null
        reconnectScheduled = true
        val delay = retrySeconds
        retrySeconds = (retrySeconds * 2).coerceAtMost(15)
        return delay
    }

    @Synchronized
    fun close(): T? {
        closed = true
        connecting = false
        reconnectScheduled = false
        return active.also { active = null }
    }
}

/** Foreground low-latency coordination; FCM remains the wake path. */
internal class CallEventStream(
    private val session: DeviceSession,
    private val onEvent: (CallCoordinationEvent) -> Unit,
) : WebSocketListener(), AutoCloseable {
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "ptt-call-events").apply { isDaemon = true }
    }
    private val client = OkHttpClient.Builder().pingInterval(25, TimeUnit.SECONDS).build()
    private val connectionState = CallEventConnectionState<WebSocket>()

    fun start() = connect()

    private fun connect() {
        val url = callEventWebSocketUrl(session.serverUrl, BuildConfig.DEBUG) ?: return
        if (!connectionState.beginConnect()) return
        val newSocket = client.newWebSocket(
            Request.Builder().url(url).header("Authorization", "Bearer ${session.accessToken}").build(),
            this,
        )
        if (!connectionState.attach(newSocket)) newSocket.close(1000, "APP_STOPPED")
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        if (!connectionState.opened(webSocket)) webSocket.close(1000, "STALE_CONNECTION")
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        if (!connectionState.accepts(webSocket)) return
        runCatching {
            val value = JSONObject(text)
            require(value.optInt("protocolVersion") == 1)
            val callId = UUID.fromString(value.getString("callId")).toString().lowercase()
            val type = value.getString("type")
            require(type in setOf("ringing", "answered", "roster_changed", "ended"))
            CallCoordinationEvent(callId, type)
        }.onSuccess(onEvent)
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = reconnect(webSocket)
    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = reconnect(webSocket)

    private fun reconnect(webSocket: WebSocket) {
        val delay = connectionState.reconnectDelay(webSocket) ?: return
        scheduler.schedule(::connect, delay, TimeUnit.SECONDS)
    }

    override fun close() {
        connectionState.close()?.close(1000, "APP_STOPPED")
        scheduler.shutdownNow()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}
