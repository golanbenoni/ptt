package app.ptt.talk

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal data class DeviceLinkInvite(
    val serverUrl: String,
    val requestId: String,
    val linkCode: String,
)

internal fun deviceLinkInviteUrl(serverUrl: String, requestId: String, linkCode: String): String? {
    val server = serverUrl.trim().trimEnd('/')
    if (!validDeviceLinkServer(server) || requestId.isBlank() || linkCode.isBlank()) return null
    val payload =
        listOf("server" to server, "requestId" to requestId.trim(), "code" to linkCode.trim())
            .joinToString("&") { (name, value) -> "$name=${encodeInviteValue(value)}" }
    return "https://ptttalk.app/link-device#$payload"
}

internal fun deviceLinkInvite(value: String): DeviceLinkInvite? {
    val uri = runCatching { URI.create(value) }.getOrNull() ?: return null
    val universal = uri.scheme.equals("https", true) && uri.host.equals("ptttalk.app", true) && uri.path == "/link-device"
    val appLink = uri.scheme.equals("ptttalk", true) && uri.host.equals("link-device", true)
    if (!universal && !appLink) return null
    val encoded = uri.rawFragment ?: uri.rawQuery ?: return null
    val pairs =
        runCatching {
            encoded.split('&').mapNotNull { pair ->
            val separator = pair.indexOf('=')
            if (separator <= 0) null else decodeInviteValue(pair.substring(0, separator)) to decodeInviteValue(pair.substring(separator + 1))
            }
        }.getOrNull() ?: return null
    if (pairs.map { it.first }.distinct().size != pairs.size) return null
    val values = pairs.toMap()
    val server = values["server"]?.trim()?.trimEnd('/') ?: return null
    val requestId = values["requestId"]?.trim() ?: return null
    val linkCode = values["code"]?.trim() ?: return null
    if (!validDeviceLinkServer(server) || requestId.length !in 8..64 || linkCode.length !in 32..256) return null
    return DeviceLinkInvite(server, requestId, linkCode)
}

private fun validDeviceLinkServer(value: String): Boolean =
    runCatching {
        val uri = URI.create(value)
        uri.scheme.equals("https", true) && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.query == null && uri.fragment == null && (uri.path.isNullOrEmpty() || uri.path == "/")
    }.getOrDefault(false)

@Suppress("DEPRECATION")
private fun encodeInviteValue(value: String): String =
    URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")

@Suppress("DEPRECATION")
private fun decodeInviteValue(value: String): String =
    URLDecoder.decode(value, StandardCharsets.UTF_8.name())
