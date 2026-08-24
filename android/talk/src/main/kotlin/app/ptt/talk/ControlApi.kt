package app.ptt.talk

import android.util.Base64
import java.net.HttpURLConnection
import java.net.URI
import java.security.SecureRandom
import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

internal data class ChannelSummary(
    val channelId: String,
    val displayName: String,
    val kind: String,
    val distributionId: String,
    val membershipEpoch: Int,
    val retentionDays: Int,
    val role: String,
)

internal data class RecoveryClaim(
    val requestId: String,
    val claimToken: String,
    val status: String,
)

internal data class RecoveryStatus(
    val status: String,
    val aci: String?,
    val deviceId: Int?,
    val mailboxId: String?,
)

internal data class RelayCredential(
    val relayAddress: String,
    val ticket: String,
    val demuxToken: String,
    /** Unsigned 32-bit wire value represented as Long because Kotlin/JSON has no UInt type. */
    val senderDemux: Long,
    val expiresAt: Instant,
)

internal data class FloorGrant(
    val granted: Boolean,
    val requestToken: String,
    val grantedTotMs: Int,
    val reason: String?,
)

internal data class DeviceSummary(
    val deviceId: Int,
    val displayName: String,
    val status: String,
)

internal data class DeviceLinkStart(val requestId: String, val linkCode: String)

internal data class AdminConsoleHandoff(val adminUrl: String, val handoffCode: String, val expiresAt: Instant)

internal data class DeviceLinkStatus(
    val aci: String,
    val deviceId: Int,
    val mailboxId: String,
    val status: String,
)

internal data class ChannelDevice(
    val aci: String,
    val deviceId: Int,
    val mailboxId: String,
    val identityKey: ByteArray,
    val role: String,
)

internal data class OneTimePreKeyUpload(val kind: String, val keyId: Int, val publicKey: ByteArray)

internal data class FetchedPreKey(
    val aci: String,
    val deviceId: Int,
    val opaqueBundle: ByteArray,
    val oneTimePreKeys: List<OneTimePreKeyUpload>,
)

internal data class MailboxRecipient(val aci: String, val deviceId: Int, val envelope: ByteArray)

internal data class MailboxItem(
    val itemId: String,
    val messageId: String,
    val envelope: ByteArray,
)

internal data class HistoryMetadata(
    val objectId: String,
    val talkId: String,
    val channelId: String,
    val membershipEpoch: Int,
    val mediaKid: ULong,
    val startedAt: Instant,
    val durationMs: Int,
    val expiresAt: Instant,
    val ciphertextBytes: Long,
)

internal data class DownloadedHistory(
    val metadata: HistoryMetadata,
    val ciphertext: ByteArray,
)

internal class ControlApi(serverUrl: String) {
    private val base = serverUrl.trimEnd('/')

    init {
        val uri = URI.create(base)
        val localDebug =
            BuildConfig.DEBUG &&
                uri.scheme == "http" &&
                uri.host in setOf("127.0.0.1", "localhost", "10.0.2.2")
        require(uri.scheme == "https" || localDebug) { "The server must use HTTPS." }
        require(!uri.host.isNullOrBlank()) { "Enter a valid server URL." }
    }

    fun requestMagicLink(email: String, invitationCode: String) {
        request(
            "/v1/auth/magic-link/request",
            JSONObject().put("email", email).put("invitationCode", invitationCode),
        )
    }

    fun consumeMagicLink(
        token: String,
        deviceName: String,
        identityKey: ByteArray,
        resumeSecret: ByteArray,
    ): DeviceSession {
        val result =
            request(
                "/v1/auth/magic-link/consume",
                JSONObject()
                    .put("token", token)
                    .put("deviceName", deviceName)
                    .put("identityKey", identityKey.base64Url())
                    .put("resumeSecret", resumeSecret.base64Url()),
            )
        return DeviceSession(
            serverUrl = base,
            aci = result.getString("aci"),
            deviceId = result.getInt("deviceId"),
            mailboxId = result.getString("mailboxId"),
            accessToken = result.getString("accessToken"),
        )
    }

    fun requestRecovery(email: String) {
        request("/v1/auth/recovery/request", JSONObject().put("email", email))
    }

    fun consumeRecovery(token: String, deviceName: String, identityKey: ByteArray): RecoveryClaim {
        val result =
            request(
                "/v1/auth/recovery/consume",
                JSONObject()
                    .put("token", token)
                    .put("deviceName", deviceName)
                    .put("identityKey", identityKey.base64Url()),
            )
        return RecoveryClaim(
            requestId = result.getString("requestId"),
            claimToken = result.getString("claimToken"),
            status = result.getString("status"),
        )
    }

    fun recoveryStatus(pending: PendingRecovery): RecoveryStatus {
        val result =
            request(
                "/v1/auth/recovery/status",
                JSONObject()
                    .put("requestId", pending.requestId)
                    .put("claimToken", pending.claimToken),
            )
        return RecoveryStatus(
            status = result.getString("status"),
            aci = result.optString("aci").takeIf(String::isNotBlank),
            deviceId = result.optInt("deviceId").takeIf { result.has("deviceId") && !result.isNull("deviceId") },
            mailboxId = result.optString("mailboxId").takeIf(String::isNotBlank),
        )
    }

    fun channels(session: DeviceSession): List<ChannelSummary> {
        val response = request("/v1/channels", method = "GET", accessToken = session.accessToken)
        val rows = response.getJSONArray("rows")
        return buildList {
            for (index in 0 until rows.length()) {
                val row = rows.getJSONObject(index)
                add(
                    ChannelSummary(
                        channelId = row.getString("channelId"),
                        displayName = row.getString("displayName"),
                        kind = row.getString("kind"),
                        distributionId = row.getString("distributionId"),
                        membershipEpoch = row.getInt("membershipEpoch"),
                        retentionDays = row.getInt("retentionDays"),
                        role = row.getString("role"),
                    ),
                )
            }
        }
    }

    fun channelDevices(session: DeviceSession, channelId: String): List<ChannelDevice> {
        val rows =
            request("/v1/channels/$channelId/devices", method = "GET", accessToken = session.accessToken)
                .getJSONArray("rows")
        return buildList {
            repeat(rows.length()) { index ->
                val row = rows.getJSONObject(index)
                add(
                    ChannelDevice(
                        aci = row.getString("aci"),
                        deviceId = row.getInt("deviceId"),
                        mailboxId = row.getString("mailboxId"),
                        identityKey = row.getString("identityKey").base64UrlBytes(),
                        role = row.getString("role"),
                    ),
                )
            }
        }
    }

    fun uploadPreKeys(
        session: DeviceSession,
        opaqueBundle: ByteArray,
        oneTimePreKeys: List<OneTimePreKeyUpload>,
    ) {
        val keys = JSONArray()
        oneTimePreKeys.forEach { key ->
            keys.put(
                JSONObject()
                    .put("kind", key.kind)
                    .put("keyId", key.keyId)
                    .put("publicKey", key.publicKey.base64Url()),
            )
        }
        request(
            "/v1/prekeys/upload",
            JSONObject().put("opaqueBundle", opaqueBundle.base64Url()).put("oneTimePrekeys", keys),
            accessToken = session.accessToken,
        )
    }

    fun fetchPreKeys(session: DeviceSession, devices: List<Pair<String, Int>>): List<FetchedPreKey> {
        require(devices.isNotEmpty()) { "at least one device is required" }
        val references = JSONArray()
        devices.forEach { (aci, deviceId) ->
            references.put(JSONObject().put("aci", aci).put("deviceId", deviceId))
        }
        val rows =
            request(
                "/v1/prekeys/fetch",
                JSONObject().put("devices", references),
                accessToken = session.accessToken,
            ).getJSONArray("rows")
        return buildList {
            repeat(rows.length()) { index ->
                val row = rows.getJSONObject(index)
                val keys = row.getJSONArray("oneTimePrekeys")
                add(
                    FetchedPreKey(
                        aci = row.getString("aci"),
                        deviceId = row.getInt("deviceId"),
                        opaqueBundle = row.getString("opaqueBundle").base64UrlBytes(),
                        oneTimePreKeys =
                            buildList {
                                repeat(keys.length()) { keyIndex ->
                                    val key = keys.getJSONObject(keyIndex)
                                    add(
                                        OneTimePreKeyUpload(
                                            key.getString("kind"),
                                            key.getInt("keyId"),
                                            key.getString("publicKey").base64UrlBytes(),
                                        ),
                                    )
                                }
                            },
                    ),
                )
            }
        }
    }

    fun enqueueMailbox(
        session: DeviceSession,
        messageId: String,
        recipients: List<MailboxRecipient>,
        expiresAt: Instant,
    ): Int {
        val encoded = JSONArray()
        recipients.forEach { recipient ->
            encoded.put(
                JSONObject()
                    .put("aci", recipient.aci)
                    .put("deviceId", recipient.deviceId)
                    .put("envelope", recipient.envelope.base64Url()),
            )
        }
        return request(
            "/v1/mailbox/envelopes",
            JSONObject()
                .put("messageId", messageId)
                .put("recipients", encoded)
                .put("expiresAt", expiresAt.toString()),
            accessToken = session.accessToken,
        ).getInt("acceptedRecipients")
    }

    fun mailboxItems(session: DeviceSession, limit: Int = 100): List<MailboxItem> {
        require(limit in 1..100)
        val rows =
            request("/v1/mailbox/items?limit=$limit", method = "GET", accessToken = session.accessToken)
                .getJSONArray("rows")
        return buildList {
            repeat(rows.length()) { index ->
                val row = rows.getJSONObject(index)
                add(
                    MailboxItem(
                        row.getString("itemId"),
                        row.getString("messageId"),
                        row.getString("envelope").base64UrlBytes(),
                    ),
                )
            }
        }
    }

    fun acknowledgeMailbox(session: DeviceSession, itemIds: List<String>): Int {
        require(itemIds.isNotEmpty())
        return request(
            "/v1/mailbox/ack",
            JSONObject().put("itemIds", JSONArray(itemIds)),
            accessToken = session.accessToken,
        ).getInt("acknowledged")
    }

    fun uploadHistory(
        session: DeviceSession,
        announcement: MediaEpochAnnouncement,
        startedAt: Instant,
        durationMs: Int,
        ciphertext: ByteArray,
    ): HistoryMetadata {
        require(durationMs in 1..30_000 && ciphertext.isNotEmpty())
        return historyMetadata(
            request(
                "/v1/history/objects",
                JSONObject()
                    .put("talkId", announcement.talkId.toString())
                    .put("channelId", announcement.channelId.toString())
                    .put("membershipEpoch", announcement.membershipEpoch)
                    .put("mediaKid", announcement.kid.toString())
                    .put("startedAt", startedAt.toString())
                    .put("durationMs", durationMs)
                    .put("ciphertext", ciphertext.base64Url()),
                accessToken = session.accessToken,
            ),
        )
    }

    fun history(session: DeviceSession, channelId: String, limit: Int = 100): List<HistoryMetadata> {
        require(limit in 1..100)
        val rows = request(
            "/v1/history/objects?channelId=$channelId&limit=$limit",
            method = "GET",
            accessToken = session.accessToken,
        ).getJSONArray("rows")
        return List(rows.length()) { historyMetadata(rows.getJSONObject(it)) }
    }

    fun downloadHistory(session: DeviceSession, objectId: String): DownloadedHistory {
        val response = request(
            "/v1/history/objects/$objectId",
            method = "GET",
            accessToken = session.accessToken,
        )
        return DownloadedHistory(
            historyMetadata(response.getJSONObject("metadata")),
            response.getString("ciphertext").base64UrlBytes(),
        )
    }

    fun revokeThisDevice(session: DeviceSession) {
        revokeDevice(session, session.deviceId)
    }

    fun deleteAccount(session: DeviceSession) {
        request(
            "/v1/account/delete",
            JSONObject().put("confirmation", "DELETE"),
            accessToken = session.accessToken,
        )
    }

    fun revokeDevice(session: DeviceSession, deviceId: Int) {
        require(deviceId in 1..2)
        request(
            "/v1/devices/revoke",
            JSONObject().put("deviceId", deviceId),
            accessToken = session.accessToken,
        )
    }

    fun devices(session: DeviceSession): List<DeviceSummary> {
        val rows = request("/v1/devices", method = "GET", accessToken = session.accessToken).getJSONArray("rows")
        return buildList {
            repeat(rows.length()) { index ->
                val row = rows.getJSONObject(index)
                add(DeviceSummary(row.getInt("deviceId"), row.getString("displayName"), row.getString("status")))
            }
        }
    }

    fun startDeviceLink(session: DeviceSession): DeviceLinkStart {
        val response = request("/v1/devices/link/start", JSONObject(), accessToken = session.accessToken)
        return DeviceLinkStart(response.getString("requestId"), response.getString("linkCode"))
    }

    fun startAdminConsoleSession(session: DeviceSession): AdminConsoleHandoff {
        val result = request(
            "/v1/admin/session/start",
            JSONObject(),
            accessToken = session.accessToken,
        )
        return AdminConsoleHandoff(
            adminUrl = result.getString("adminUrl"),
            handoffCode = result.getString("handoffCode"),
            expiresAt = Instant.parse(result.getString("expiresAt")),
        )
    }

    fun claimDeviceLink(
        requestId: String,
        linkCode: String,
        deviceName: String,
        identityKey: ByteArray,
    ): PendingDeviceLink {
        val response =
            request(
                "/v1/devices/link/claim",
                JSONObject()
                    .put("requestId", requestId)
                    .put("linkCode", linkCode)
                    .put("deviceName", deviceName)
                    .put("identityKey", identityKey.base64Url()),
            )
        return PendingDeviceLink(
            serverUrl = base,
            requestId = requestId,
            aci = response.getString("aci"),
            deviceId = response.getInt("deviceId"),
            mailboxId = response.getString("mailboxId"),
            claimToken = response.getString("claimToken"),
        )
    }

    fun approveDeviceLink(session: DeviceSession, requestId: String) {
        request(
            "/v1/devices/link/approve",
            JSONObject().put("requestId", requestId),
            accessToken = session.accessToken,
        )
    }

    fun deviceLinkStatus(link: PendingDeviceLink): DeviceLinkStatus {
        val response = request("/v1/devices/link/status", JSONObject().put("claimToken", link.claimToken))
        return DeviceLinkStatus(
            aci = response.getString("aci"),
            deviceId = response.getInt("deviceId"),
            mailboxId = response.getString("mailboxId"),
            status = response.getString("status"),
        )
    }

    fun relayCredential(session: DeviceSession, channelId: String): RelayCredential {
        val response =
            request(
                "/v1/relay/credentials",
                JSONObject().put("channelId", channelId),
                accessToken = session.accessToken,
            )
        return RelayCredential(
            relayAddress = response.getString("relayAddress"),
            ticket = response.getString("ticket"),
            demuxToken = response.getString("demuxToken"),
            senderDemux = response.getLong("senderDemux").also { require(it in 1..0xffff_ffffL) },
            expiresAt = Instant.parse(response.getString("expiresAt")),
        )
    }

    fun requestFloor(
        session: DeviceSession,
        channel: ChannelSummary,
        relay: RelayCredential,
        requestToken: String = ByteArray(16).also(SecureRandom()::nextBytes).base64Url(),
        requestedTotMs: Int = 30_000,
        sos: Boolean = false,
    ): FloorGrant {
        val response =
            request(
                "/v1/floor/request",
                JSONObject()
                    .put("channelId", channel.channelId)
                    .put("requestToken", requestToken)
                    .put("senderDemux", relay.senderDemux)
                    .put("membershipEpoch", channel.membershipEpoch)
                    .put("requestedTotMs", requestedTotMs)
                    .put("sos", sos),
                accessToken = session.accessToken,
            )
        return FloorGrant(
            granted = response.getBoolean("granted"),
            requestToken = response.getString("requestToken"),
            grantedTotMs = response.getInt("grantedTotMs"),
            reason = response.optString("reason").takeIf(String::isNotBlank),
        )
    }

    fun releaseFloor(session: DeviceSession, channelId: String, requestToken: String) {
        request(
            "/v1/floor/release",
            JSONObject().put("channelId", channelId).put("requestToken", requestToken),
            accessToken = session.accessToken,
        )
    }

    fun registerFcm(session: DeviceSession, token: String) {
        require(token.length in 16..4_096)
        request(
            "/v1/push/registrations",
            JSONObject().put("provider", "fcm").put("token", token.encodeToByteArray().base64Url()),
            accessToken = session.accessToken,
        )
    }

    fun removeFcm(session: DeviceSession) {
        request(
            "/v1/push/registrations",
            JSONObject().put("provider", "fcm"),
            method = "DELETE",
            accessToken = session.accessToken,
        )
    }

    fun setPresence(session: DeviceSession, mode: String) {
        require(mode in setOf("available", "busy", "solo", "standby"))
        request(
            "/v1/presence",
            JSONObject().put("mode", mode),
            accessToken = session.accessToken,
        )
    }

    private fun request(
        path: String,
        body: JSONObject? = null,
        method: String = "POST",
        accessToken: String? = null,
    ): JSONObject {
        val connection = URI.create(base + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Cache-Control", "no-store")
            accessToken?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().encodeToByteArray()) }
            }
            val code = connection.responseCode
            val bytes =
                (if (code in 200..299) connection.inputStream else connection.errorStream)
                    ?.use { it.readBytes() }
                    ?: ByteArray(0)
            val text = bytes.decodeToString()
            if (code !in 200..299) {
                val error = runCatching { JSONObject(text).optString("code") }.getOrNull()
                throw ControlApiException(code, error?.takeIf(String::isNotBlank) ?: "REQUEST_FAILED")
            }
            if (text.isBlank()) return JSONObject()
            return if (text.first() == '[') JSONObject().put("rows", JSONArray(text)) else JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }

    private fun historyMetadata(value: JSONObject): HistoryMetadata =
        HistoryMetadata(
            objectId = value.getString("objectId"),
            talkId = value.getString("talkId"),
            channelId = value.getString("channelId"),
            membershipEpoch = value.getInt("membershipEpoch"),
            mediaKid = value.getString("mediaKid").toULong(),
            startedAt = Instant.parse(value.getString("startedAt")),
            durationMs = value.getInt("durationMs"),
            expiresAt = Instant.parse(value.getString("expiresAt")),
            ciphertextBytes = value.getLong("ciphertextBytes"),
        )

    private fun ByteArray.base64Url(): String =
        Base64.encodeToString(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun String.base64UrlBytes(): ByteArray =
        Base64.decode(this, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

internal class ControlApiException(val status: Int, val code: String) :
    Exception("$code ($status)")
