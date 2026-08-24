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

    override fun onOpen(webSocket: WebSocket, response: Response) {
        socket = webSocket
        opened.countDown()
    }

    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
        val packet = bytes.toByteArray()
        if (packet.size == MEDIA_DATAGRAM_BYTES) onMedia(packet)
        else fail(IllegalArgumentException("TLS relay returned an invalid media datagram"))
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
        val failedWhileOpening = opened.count > 0
        openingError.compareAndSet(null, t)
        opened.countDown()
        if (!closed && !failedWhileOpening) onError(t)
    }

    @Synchronized
    override fun send(packet: ByteArray) {
        require(packet.size == MEDIA_DATAGRAM_BYTES) { "relay accepts only production media datagrams" }
        check(!closed) { "relay connection is closed" }
        check(socket?.send(packet.toByteString()) == true) { "TLS relay send queue is closed" }
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        socket?.close(1000, "session closed")
        socket = null
    }

    private fun fail(error: Throwable) {
        close()
        onError(error)
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
) : MediaRelay {
    private var current: MediaRelay = initial
    private var closed = false

    @Synchronized
    override fun send(packet: ByteArray) {
        check(!closed) { "relay connection is closed" }
        current.send(packet)
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
                ) { error -> holder[0]?.switchToTls(error) ?: onError(error) }
            }.getOrElse {
                val fallback = TlsMediaRelay.connect(serverUrl, accessToken, channelId, onMedia, onError)
                return AdaptiveMediaRelay(
                    fallback, serverUrl, accessToken, channelId, onMedia, onError, onTransportChanged,
                ).also { onTransportChanged("UDP unavailable; encrypted media is using TLS.") }
            }
            return AdaptiveMediaRelay(
                udp, serverUrl, accessToken, channelId, onMedia, onError, onTransportChanged,
            ).also { holder[0] = it }
        }
    }
}
