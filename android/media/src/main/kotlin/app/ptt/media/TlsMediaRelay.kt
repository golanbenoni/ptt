package app.ptt.media

import java.io.IOException
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
    @Volatile private var pendingRelease: PendingRelease? = null

    private class PendingFloor(val requestToken: String) {
        val completed = CountDownLatch(1)
        val result = AtomicReference<MediaFloorGrant?>()
        val error = AtomicReference<Throwable?>()
    }

    private class PendingRelease(val requestToken: String) {
        val completed = CountDownLatch(1)
        val result = AtomicReference<Boolean?>()
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
        if (text.length > 512) {
            fail(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            return
        }
        val type = jsonString(text, "type")
        val requestToken = jsonString(text, "requestToken")
        val release = pendingRelease
        if (release != null) {
            if (requestToken != release.requestToken) {
                fail(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
                return
            }
            synchronized(this) {
                if (pendingRelease !== release) return
                pendingRelease = null
            }
            if (type == "floor.error") {
                release.error.set(MediaFloorControlException(jsonString(text, "code") ?: "FLOOR_RELEASE_FAILED"))
            } else if (type == "floor.released") {
                val released = jsonBoolean(text, "released")
                if (released == null) release.error.set(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
                else release.result.set(released)
            } else {
                release.error.set(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            }
            release.completed.countDown()
            return
        }
        val pending = pendingFloor
        if (pending == null) {
            fail(MediaFloorControlException("INVALID_CONTROL_RESPONSE"))
            return
        }
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
        val error = MediaRelayConnectionException("TLS relay connection failed", t)
        openingError.compareAndSet(null, error)
        opened.countDown()
        val shouldNotify = synchronized(this) {
            if (closed) false
            else {
                closed = true
                socket = null
                true
            }
        }
        failPendingFloor(error)
        failPendingRelease(error)
        if (shouldNotify && !failedWhileOpening) onError(error)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
        val shouldReconnect = synchronized(this) {
            if (closed) return@synchronized false
            closed = true
            socket = null
            true
        }
        if (shouldReconnect) {
            val error = MediaRelayConnectionException(
                "TLS relay closed ($code): ${reason.ifBlank { "connection ended" }}",
            )
            failPendingFloor(error)
            failPendingRelease(error)
            onError(error)
        }
    }

    @Synchronized
    override fun send(packet: ByteArray) {
        require(packet.size == MEDIA_DATAGRAM_BYTES) { "relay accepts only production media datagrams" }
        if (closed) throw MediaRelayConnectionException("TLS relay connection is closed")
        val selected = socket ?: throw MediaRelayConnectionException("TLS relay connection is unavailable")
        if (!selected.send(packet.toByteString())) {
            closed = true
            socket = null
            selected.cancel()
            throw MediaRelayConnectionException("TLS relay send queue is closed")
        }
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
            if (closed) throw MediaRelayConnectionException("TLS relay connection is unavailable")
            check(pendingFloor == null) { "another floor request is already pending" }
            pendingFloor = pending
            socket ?: run {
                pendingFloor = null
                throw MediaRelayConnectionException("TLS relay connection is unavailable")
            }
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
            synchronized(this) { if (pendingFloor === pending) pendingFloor = null }
            throw MediaRelayConnectionException("TLS relay floor send queue is closed")
        }
        if (!pending.completed.await(3, TimeUnit.SECONDS)) {
            synchronized(this) { if (pendingFloor === pending) pendingFloor = null }
            throw MediaRelayConnectionException("TLS relay floor request timed out")
        }
        pending.error.get()?.let { throw it }
        return pending.result.get() ?: throw MediaFloorControlException("INVALID_CONTROL_RESPONSE")
    }

    override fun releaseFloor(requestToken: String): Boolean {
        require(requestToken.matches(Regex("[A-Za-z0-9_-]{22}"))) { "invalid floor token" }
        val pending = PendingRelease(requestToken)
        val webSocket = synchronized(this) {
            if (closed) throw MediaRelayConnectionException("TLS relay connection is unavailable")
            check(pendingFloor == null && pendingRelease == null) { "another floor operation is already pending" }
            pendingRelease = pending
            socket ?: run {
                pendingRelease = null
                throw MediaRelayConnectionException("TLS relay connection is unavailable")
            }
        }
        if (!webSocket.send("{\"type\":\"floor.release\",\"requestToken\":\"$requestToken\"}")) {
            synchronized(this) { if (pendingRelease === pending) pendingRelease = null }
            throw MediaRelayConnectionException("TLS relay floor release queue is closed")
        }
        if (!pending.completed.await(3, TimeUnit.SECONDS)) {
            synchronized(this) { if (pendingRelease === pending) pendingRelease = null }
            throw MediaRelayConnectionException("TLS relay floor release timed out")
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
        failPendingRelease(MediaFloorControlException("FLOOR_SOCKET_UNAVAILABLE"))
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

    private fun failPendingRelease(error: Throwable) {
        val pending = synchronized(this) {
            val value = pendingRelease
            pendingRelease = null
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
            if (relay.closed || relay.socket == null) {
                relay.close()
                throw MediaRelayConnectionException("TLS relay handshake failed")
            }
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
    private val onError: (Throwable) -> Unit,
    private val onTransportChanged: (String) -> Unit,
    private val supportsFastFloor: Boolean,
    private val tlsFactory: ((Throwable) -> Unit) -> MediaRelay,
) : MediaRelay {
    private var current: MediaRelay = initial
    private var closed = false

    override fun send(packet: ByteArray) {
        withRecovery { selected -> selected.send(packet) }
    }

    override fun requestFloor(
        requestToken: String,
        membershipEpoch: Int,
        requestedTotMs: Int,
        sos: Boolean,
    ): MediaFloorGrant? {
        if (!supportsFastFloor) return null
        return withRecovery { selected ->
            selected.requestFloor(requestToken, membershipEpoch, requestedTotMs, sos)
        }
    }

    override fun releaseFloor(requestToken: String): Boolean? {
        if (!supportsFastFloor) return null
        return withRecovery { selected -> selected.releaseFloor(requestToken) }
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        current.close()
    }

    private fun <T> withRecovery(operation: (MediaRelay) -> T): T {
        val selected = synchronized(this) {
            if (closed) throw MediaRelayConnectionException("relay connection is closed")
            current
        }
        return try {
            operation(selected)
        } catch (error: Throwable) {
            if (!isRecoverableTransportFailure(error)) throw error
            operation(recover(selected, error).first)
        }
    }

    private fun recover(expected: MediaRelay, transportError: Throwable): Pair<MediaRelay, Boolean> {
        val recovered = synchronized(this) {
            if (closed) throw MediaRelayConnectionException("relay connection is closed", transportError)
            if (current !== expected) return@synchronized current to false
            val replacement = try {
                createTlsRelay()
            } catch (tlsError: Throwable) {
                tlsError.addSuppressed(transportError)
                throw tlsError
            }
            current = replacement
            expected.close()
            replacement to true
        }
        if (recovered.second) {
            onTransportChanged("Encrypted media reconnected over TLS.")
        }
        return recovered
    }

    private fun createTlsRelay(): MediaRelay {
        val source = AtomicReference<MediaRelay?>()
        val relay = tlsFactory { error ->
            source.get()?.let { failed -> recoverAsync(failed, error) } ?: onError(error)
        }
        source.set(relay)
        return relay
    }

    private fun recoverAsync(expected: MediaRelay, transportError: Throwable) {
        runCatching { recover(expected, transportError) }
            .onFailure(onError)
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
            val source = AtomicReference<MediaRelay?>()
            val transportFailure: (Throwable) -> Unit = { error ->
                val relay = source.get()
                val adaptive = holder[0]
                if (relay != null && adaptive != null) adaptive.recoverAsync(relay, error)
                else onError(error)
            }
            val tlsFactory: ((Throwable) -> Unit) -> MediaRelay = { failure ->
                TlsMediaRelay.connect(serverUrl, accessToken, channelId, onMedia, failure)
            }
            val udp = runCatching {
                AuthenticatedUdpRelay.connect(
                    publicAddress,
                    ticket,
                    expectedSenderDemux,
                    onMedia,
                    onError = transportFailure,
                )
            }.getOrElse {
                val fallback = tlsFactory(transportFailure)
                source.set(fallback)
                return AdaptiveMediaRelay(
                    fallback, onError, onTransportChanged, supportsFastFloor, tlsFactory,
                ).also {
                    holder[0] = it
                    onTransportChanged("UDP unavailable; encrypted media is using TLS.")
                }
            }
            source.set(udp)
            return AdaptiveMediaRelay(udp, onError, onTransportChanged, supportsFastFloor, tlsFactory)
                .also { holder[0] = it }
        }

        internal fun createForTest(
            initial: MediaRelay,
            supportsFastFloor: Boolean = true,
            onError: (Throwable) -> Unit = {},
            onTransportChanged: (String) -> Unit = {},
            tlsFactory: ((Throwable) -> Unit) -> MediaRelay,
        ): AdaptiveMediaRelay {
            return AdaptiveMediaRelay(
                initial,
                onError,
                onTransportChanged,
                supportsFastFloor,
                tlsFactory,
            )
        }
    }
}

private fun isRecoverableTransportFailure(error: Throwable): Boolean =
    generateSequence(error) { it.cause }.any { it is IOException }

private fun jsonString(json: String, key: String): String? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*\\\"([A-Za-z0-9_. -]{1,128})\\\"")
        .find(json)?.groupValues?.get(1)

private fun jsonInteger(json: String, key: String): Int? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*([0-9]{1,10})")
        .find(json)?.groupValues?.get(1)?.toIntOrNull()

private fun jsonBoolean(json: String, key: String): Boolean? =
    Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*(true|false)")
        .find(json)?.groupValues?.get(1)?.toBooleanStrictOrNull()
