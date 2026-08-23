package app.ptt.net

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class PrekeyServer(port: Int = 0, bind: String = "127.0.0.1") : AutoCloseable {
    private val bundles = ConcurrentHashMap<UUID, String>()
    private val server: HttpServer = HttpServer.create(InetSocketAddress(bind, port), 0)

    val port: Int get() = server.address.port
    val bindHost: String = bind
    val baseUrl: String get() = "http://$bindHost:$port"

    init {
        server.createContext("/v1/prekeys/") { ex ->
            val path = ex.requestURI.path.removePrefix("/v1/prekeys/")
            val aci = runCatching { UUID.fromString(path) }.getOrNull()
            if (aci == null) {
                ex.sendResponseHeaders(400, -1)
                ex.close()
                return@createContext
            }
            when (ex.requestMethod) {
                "PUT" -> {
                    val body = ex.requestBody.readBytes().decodeToString()
                    bundles[aci] = body
                    val ok = "{\"ok\":true}".toByteArray()
                    ex.sendResponseHeaders(200, ok.size.toLong())
                    ex.responseBody.use { it.write(ok) }
                }
                "GET" -> {
                    val raw = bundles[aci]
                    if (raw == null) {
                        ex.sendResponseHeaders(404, -1)
                    } else {
                        // consume one-time prekey after fetch (device-shaped)
                        try {
                            val dto = BundleJson.fromJson(raw)
                            val consumed = dto.copy(preKeyId = null, preKey = null)
                            bundles[aci] = BundleJson.toJson(consumed)
                        } catch (_: Exception) {
                            // still return the stored body; caller sees the parse error
                        }
                        val bytes = raw.toByteArray()
                        ex.responseHeaders.add("Content-Type", "application/json")
                        ex.sendResponseHeaders(200, bytes.size.toLong())
                        ex.responseBody.use { it.write(bytes) }
                    }
                }
                else -> ex.sendResponseHeaders(405, -1)
            }
            ex.close()
        }
        server.executor = Executors.newCachedThreadPool()
        server.start()
    }

    override fun close() {
        server.stop(0)
    }
}
