package app.ptt.media

import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString

/** Device-authenticated, ciphertext-only media tunnel over WebSocket TLS. */
class TlsMediaRelay private constructor(
    private val onMedia: (ByteArray) -> Unit,
    private val onError: (Throwable) -> Unit,
) : WebSocketListener(), MediaRelay {
    private val opened = CountDownLatch(1)
    private val openingError = AtomicReference<Throwable?>()
    @Volatile private var socket: WebSocket? = null
    @Volatile private var closed = false
    @Volatile private var pendingFloor: PendingFloor? = null

    private class PendingFloor(val requestToken: String) {
        val completed = CountDownLatch(1)
        val result = AtomicReference<MediaFloorGrant?>()
        val error = AtomicReference<Throwable?>()
    }

    override fun onOpen(webSocket: WebSocket, response: Response) {
        socket = webSocket
        opened.countDown()
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        val packet = bytes.toByteArray()
        if (packet.size == MEDIA_DATAGRAM_BYTES) onMedia(packet)
        else fail(IllegalArgumentException("TLS relay returned an invalid media datagram"))
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
        val pending = pendingFloor
        if (pending == null || text.length > 512) {
            fail(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            return
        }
        val type = jsonString(text, "type")
        val requestToken = jsonString(text, "requestToken")
        if (requestToken != pending.requestToken) {
            fail(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            return
        }
        synchronized(this) {
            if (pendingFloor !== pending) return
            pendingFloor = null
        }
        if (type == "floor.error") {
            pending.error.set(MediaFloorControlException(jsonString(text, "code") ?: "FLOOR_REQUEST_FAILED"))
        } else if (type == "floor.result") {
            val granted = jsonBoolean(text, "granted")
            val grantedTotMs = jsonInteger(text, "grantedTotMs")
            if (granted == null || grantedTotMs == null || grantedTotMs !in 1_000..30_000) {
                pending.error.set(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            } else {
                pending.result.set(
                    MediaFloorGrant(granted, requestToken, grantedTotMs, jsonString(text, "reason")),
                )
            }
        } else {
            pending.error.set(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
        }
        pending.completed.countDown()
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        val failedWhileOpening = opened.count > 0
        openingError.compareAndSet(null, t)
        opened.countDown()
        failPendingFloor(t)
        if (!closed && !failedWhileOpening) onError(t)
    }

    @Synchronized
    override fun send(packet: ByteArray) {
        require(packet.size == MEDIA_DATAGRAM_BYTES) { "relay accepts only production media datagrams" }
        check(!closed) { "relay connection is closed" }
        check(socket?.send(packet.toByteString()) == true) { "TLS relay send queue is closed" }
    }

    override fun requestFloor(
        requestToken: String,
        membershipEpoch: Int,
        requestedTotMs: Int,
        sos: Boolean,
    ): MediaFloorGrant? {
        require(requestToken.matches(Regex("[A-Za-z0-9_-]{22}"))) { "invalid floor token" }
        require(membershipEpoch in 1..Int.MAX_VALUE && requestedTotMs in 1_000..30_000)
        val pending = PendingFloor(requestToken)
        val webSocket = synchronized(this) {
            check(!closed && pendingFloor == null) { "relay connection is unavailable" }
            pendingFloor = pending
            checkNotNull(socket) { "relay connection is unavailable" }
        }
        val text = buildString(160) {
            append("{\"type\":\"floor.request\",\"requestToken\":\"")
            append(requestToken)
            append("\",\"membershipEpoch\":")
            append(membershipEpoch)
            append(",\"requestedTotMs\":")
            append(requestedTotMs)
            append(",\"sos\":")
            append(sos)
            append('}')
        }
        if (!webSocket.send(text)) {
            failPendingFloor(MediaFloorControlException("FLOOR_SOCKET_UNAVAILABLE"))
        }
        if (!pending.completed.await(3, TimeUnit.SECONDS)) {
            synchronized(this) { if (pendingFloor === pending) pendingFloor = null }
            throw MediaFloorControlException("FLOOR_REQUEST_TIMEOUT")
        }
        pending.error.get()?.let { throw it }
        return pending.result.get() ?: throw MediaFloorControlException("INVALID_CONTROL_RESPONSE")
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        socket?.close(1000, "session closed")
        socket = null
        failPendingFloor(MediaFloorControlException("FLOOR_SOCKET_UNAVAILABLE"))
    }

    private fun fail(error: Throwable) {
        close()
        onError(error)
    }

    private fun failPendingFloor(error: Throwable) {
        val pending = synchronized(this) {
            val value = pendingFloor
            pendingFloor = null
            value
        } ?: return
        pending.error.compareAndSet(null, error)
        pending.completed.countDown()
    }

    companion object {
        private val client =
            OkHttpClient.Builder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .build()

        fun connect(
            serverUrl: String,
            accessToken: String,
            channelId: String,
            onMedia: (ByteArray) -> Unit,
            onError: (Throwable) -> Unit = {},
        ): TlsMediaRelay {
            require(accessToken.isNotBlank() && accessToken.length <= 4_096) { "invalid device token" }
            val relay = TlsMediaRelay(onMedia, onError)
            val request =
                Request.Builder()
                    .url(tlsMediaWebSocketUrl(serverUrl, channelId))
                    .header("Authorization", "Bearer $accessToken")
                    .build()
            relay.socket = client.newWebSocket(request, relay)
            if (!relay.opened.await(5, TimeUnit.SECONDS)) {
                relay.close()
                error("TLS relay handshake timed out")
            }
            relay.openingError.get()?.let { relay.close(); throw it }
            check(!relay.closed && relay.socket != null) { "TLS relay handshake failed" }
            return relay
        }
    }
}

internal fun tlsMediaWebSocketUrl(serverUrl: String, channelId: String): String {
    val channel = runCatching { java.util.UUID.fromString(channelId) }.getOrElse {
        throw IllegalArgumentException("invalid channel ID", it)
    }
    val base = URI.create(serverUrl.trimEnd('/'))
    require(base.host != null && base.userInfo == null) { "invalid TLS relay server" }
    val scheme = when (base.scheme?.lowercase()) {
        "https" -> "wss"
        "http" -> "ws"
        else -> throw IllegalArgumentException("TLS relay server must use HTTP or HTTPS")
    }
    return URI(
        scheme,
        null,
        base.host,
        base.port,
        "/v1/media/tunnel",
        "channelId=$channel",
        null,
    ).toASCIIString()
}

/** Starts on UDP and atomically moves to TLS if UDP setup or receive fails. */
class AdaptiveMediaRelay private constructor(
    initial: MediaRelay,
    private val serverUrl: String,
    private val accessToken: String,
    private val channelId: String,
    private val onMedia: (ByteArray) -> Unit,
    private val onError: (Throwable) -> Unit,
    private val onTransportChanged: (String) -> Unit,
    private val supportsFastFloor: Boolean,
) : MediaRelay {
    private var current: MediaRelay = initial
    private var closed = false

    @Synchronized
    override fun send(packet: ByteArray) {
        check(!closed) { "relay connection is closed" }
        try {
            current.send(packet)
        } catch (udpError: Throwable) {
            if (current is TlsMediaRelay) throw udpError
            switchToTls(udpError)
            if (current !is TlsMediaRelay) throw udpError
            current.send(packet)
        }
    }

    override fun requestFloor(
        requestToken: String,
        membershipEpoch: Int,
        requestedTotMs: Int,
        sos: Boolean,
    ): MediaFloorGrant? {
        if (!supportsFastFloor) return null
        val selected = synchronized(this) {
            check(!closed) { "relay connection is closed" }
            current
        }
        return selected.requestFloor(requestToken, membershipEpoch, requestedTotMs, sos)
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        current.close()
    }

    @Synchronized
    private fun switchToTls(udpError: Throwable) {
        if (closed || current is TlsMediaRelay) return
        runCatching {
            TlsMediaRelay.connect(serverUrl, accessToken, channelId, onMedia, onError)
        }.onSuccess { fallback ->
            val previous = current
            current = fallback
            previous.close()
            onTransportChanged("UDP unavailable; encrypted media switched to TLS.")
        }.onFailure { tlsError ->
            tlsError.addSuppressed(udpError)
            onError(tlsError)
        }
    }

    companion object {
        fun connect(
            serverUrl: String,
            accessToken: String,
            channelId: String,
            publicAddress: String,
            ticket: String,
            expectedSenderDemux: Long,
            supportsFastFloor: Boolean = false,
            onMedia: (ByteArray) -> Unit,
            onError: (Throwable) -> Unit = {},
            onTransportChanged: (String) -> Unit = {},
        ): AdaptiveMediaRelay {
            val holder = arrayOfNulls<AdaptiveMediaRelay>(1)
            val udp = runCatching {
                AuthenticatedUdpRelay.connect(
                    publicAddress,
                    ticket,
                    expectedSenderDemux,
                    onMedia,
                    onError = { error -> holder[0]?.switchToTls(error) ?: onError(error) },
                )
            }.getOrElse {
                val fallback = TlsMediaRelay.connect(serverUrl, accessToken, channelId, onMedia, onError)
                return AdaptiveMediaRelay(
                    fallback, serverUrl, accessToken, channelId, onMedia, onError, onTransportChanged,
                    supportsFastFloor,
                ).also { onTransportChanged("UDP unavailable; encrypted media is using TLS.") }
            }
            return AdaptiveMediaRelay(
                udp, serverUrl, accessToken, channelId, onMedia, onError, onTransportChanged,
                supportsFastFloor,
            ).also { holder[0] = it }
        }
    }
}

private fun jsonString(json: String, key: String): String? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*\\\"([A-Za-z0-9_. -]{1,128})\\\"")
        .find(json)?.groupValues?.get(1)

private fun jsonInteger(json: String, key: String): Int? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*([0-9]{1,10})")
        .find(json)?.groupValues?.get(1)?.toIntOrNull()

private fun jsonBoolean(json: String, key: String): Boolean? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*(true|false)")
        .find(json)?.groupValues?.get(1)?.toBooleanStrictOrNull()
