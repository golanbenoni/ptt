package app.ptt.talk

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal data class DeviceSession(
    val serverUrl: String,
    val aci: String,
    val deviceId: Int,
    val mailboxId: String,
    val accessToken: String,
)

internal data class PendingRecovery(
    val serverUrl: String,
    val requestId: String,
    val claimToken: String,
)

internal data class PendingDeviceLink(
    val serverUrl: String,
    val requestId: String,
    val aci: String,
    val deviceId: Int,
    val mailboxId: String,
    val claimToken: String,
)

/** Stores the device credential encrypted by a non-exportable Android Keystore key. */
internal class SecureDeviceStore(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences("device-session-v1", Context.MODE_PRIVATE)

    fun load(): DeviceSession? {
        val json = loadJson() ?: return null
        if (json.optString("kind", "session") != "session") return null
        return try {
            DeviceSession(
                serverUrl = json.getString("serverUrl"),
                aci = json.getString("aci"),
                deviceId = json.getInt("deviceId"),
                mailboxId = json.getString("mailboxId"),
                accessToken = json.getString("accessToken"),
            )
        } catch (_: Exception) {
            clear()
            null
        }
    }

    fun save(session: DeviceSession) {
        saveJson(
            JSONObject()
                .put("kind", "session")
                .put("serverUrl", session.serverUrl)
                .put("aci", session.aci)
                .put("deviceId", session.deviceId)
                .put("mailboxId", session.mailboxId)
                .put("accessToken", session.accessToken)
        )
    }

    fun savePending(recovery: PendingRecovery) {
        saveJson(
            JSONObject()
                .put("kind", "recovery")
                .put("serverUrl", recovery.serverUrl)
                .put("requestId", recovery.requestId)
                .put("claimToken", recovery.claimToken),
        )
    }

    fun loadPending(): PendingRecovery? {
        val json = loadJson() ?: return null
        if (json.optString("kind") != "recovery") return null
        return PendingRecovery(
            serverUrl = json.getString("serverUrl"),
            requestId = json.getString("requestId"),
            claimToken = json.getString("claimToken"),
        )
    }

    fun savePendingLink(link: PendingDeviceLink) {
        saveJson(
            JSONObject()
                .put("kind", "device-link")
                .put("serverUrl", link.serverUrl)
                .put("requestId", link.requestId)
                .put("aci", link.aci)
                .put("deviceId", link.deviceId)
                .put("mailboxId", link.mailboxId)
                .put("claimToken", link.claimToken),
        )
    }

    fun loadPendingLink(): PendingDeviceLink? {
        val json = loadJson() ?: return null
        if (json.optString("kind") != "device-link") return null
        return PendingDeviceLink(
            serverUrl = json.getString("serverUrl"),
            requestId = json.getString("requestId"),
            aci = json.getString("aci"),
            deviceId = json.getInt("deviceId"),
            mailboxId = json.getString("mailboxId"),
            claimToken = json.getString("claimToken"),
        )
    }

    fun saveServer(serverUrl: String) {
        saveJson(JSONObject().put("kind", "configuration").put("serverUrl", serverUrl.trimEnd('/')))
    }

    fun loadServer(): String? {
        val json = loadJson() ?: return null
        return json.optString("serverUrl").takeIf(String::isNotBlank)
    }

    private fun saveJson(value: JSONObject) {
        val json = value.toString().encodeToByteArray()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(AAD)
        val combined = cipher.iv + cipher.doFinal(json)
        preferences.edit().putString(SESSION, Base64.encodeToString(combined, Base64.NO_WRAP)).apply()
        json.fill(0)
    }

    private fun loadJson(): JSONObject? {
        val encoded = preferences.getString(SESSION, null) ?: return null
        return try {
            val combined = Base64.decode(encoded, Base64.NO_WRAP)
            require(combined.size > NONCE_BYTES + 16)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(128, combined.copyOfRange(0, NONCE_BYTES)),
            )
            cipher.updateAAD(AAD)
            JSONObject(
                cipher
                    .doFinal(combined, NONCE_BYTES, combined.size - NONCE_BYTES)
                    .decodeToString(),
            )
        } catch (_: Exception) {
            // A restored preference cannot be decrypted by a new device's
            // hardware key. Treat it as signed out and never weaken storage.
            clear()
            null
        }
    }

    fun clear() {
        preferences.edit().remove(SESSION).remove(ENROLLMENT_RESUME).apply()
    }

    fun enrollmentResumeSecret(): ByteArray {
        preferences.getString(ENROLLMENT_RESUME, null)?.let { encoded ->
            runCatching { decryptResumeSecret(encoded) }.getOrNull()?.let { secret ->
                if (secret.size == 32) return secret
                secret.fill(0)
            }
        }
        val secret = ByteArray(32).also(SecureRandom()::nextBytes)
        check(preferences.edit().putString(ENROLLMENT_RESUME, encryptResumeSecret(secret)).commit()) {
            "Could not persist secure enrollment retry state."
        }
        return secret
    }

    fun clearEnrollmentResumeSecret() {
        preferences.edit().remove(ENROLLMENT_RESUME).apply()
    }

    private fun encryptResumeSecret(secret: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(RESUME_AAD)
        return Base64.encodeToString(cipher.iv + cipher.doFinal(secret), Base64.NO_WRAP)
    }

    private fun decryptResumeSecret(encoded: String): ByteArray {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        require(combined.size > NONCE_BYTES + 16)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(128, combined.copyOfRange(0, NONCE_BYTES)),
        )
        cipher.updateAAD(RESUME_AAD)
        return cipher.doFinal(combined, NONCE_BYTES, combined.size - NONCE_BYTES)
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val SESSION = "session"
        const val ENROLLMENT_RESUME = "enrollment-resume"
        const val KEY_ALIAS = "ptt-device-session-v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val NONCE_BYTES = 12
        val AAD = "app.ptt.talk/device-session/v1".encodeToByteArray()
        val RESUME_AAD = "app.ptt.talk/enrollment-resume/v1".encodeToByteArray()
    }
}
