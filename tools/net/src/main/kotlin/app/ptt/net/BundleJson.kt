package app.ptt.net

import app.ptt.crypto.Aci
import app.ptt.crypto.PreKeyBundleDto
import java.util.Base64
import java.util.UUID

object BundleJson {
    private val b64 = Base64.getEncoder()
    private val b64d = Base64.getDecoder()

    fun toJson(b: PreKeyBundleDto): String {
        val parts = mutableListOf(
            "\"aci\":\"${b.aci.uuid}\"",
            "\"deviceId\":${b.deviceId}",
            "\"registrationId\":${b.registrationId}",
            "\"identityKey\":\"${b64.encodeToString(b.identityKey)}\"",
            "\"signedPreKeyId\":${b.signedPreKeyId}",
            "\"signedPreKey\":\"${b64.encodeToString(b.signedPreKey)}\"",
            "\"signedPreKeySig\":\"${b64.encodeToString(b.signedPreKeySig)}\"",
            "\"kyberPreKeyId\":${b.kyberPreKeyId}",
            "\"kyberPreKey\":\"${b64.encodeToString(b.kyberPreKey)}\"",
            "\"kyberPreKeySig\":\"${b64.encodeToString(b.kyberPreKeySig)}\"",
        )
        if (b.preKeyId != null && b.preKey != null) {
            parts += "\"preKeyId\":${b.preKeyId}"
            parts += "\"preKey\":\"${b64.encodeToString(b.preKey)}\""
        }
        return "{${parts.joinToString(",")}}"
    }

    fun fromJson(s: String): PreKeyBundleDto {
        fun str(key: String): String? {
            val m = Regex("\"$key\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"").find(s) ?: return null
            return m.groupValues[1]
                .replace("\\/", "/")
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
        }
        fun int(key: String): Int? {
            val m = Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(s) ?: return null
            return m.groupValues[1].toInt()
        }
        fun bytes(key: String): ByteArray? = str(key)?.let { b64d.decode(it) }
        val aci = UUID.fromString(str("aci") ?: error("aci"))
        return PreKeyBundleDto(
            aci = Aci(aci),
            deviceId = int("deviceId") ?: 1,
            registrationId = int("registrationId") ?: error("registrationId"),
            identityKey = bytes("identityKey") ?: error("identityKey"),
            signedPreKeyId = int("signedPreKeyId") ?: error("signedPreKeyId"),
            signedPreKey = bytes("signedPreKey") ?: error("signedPreKey"),
            signedPreKeySig = bytes("signedPreKeySig") ?: error("signedPreKeySig"),
            preKeyId = int("preKeyId"),
            preKey = bytes("preKey"),
            kyberPreKeyId = int("kyberPreKeyId") ?: error("kyberPreKeyId"),
            kyberPreKey = bytes("kyberPreKey") ?: error("kyberPreKey"),
            kyberPreKeySig = bytes("kyberPreKeySig") ?: error("kyberPreKeySig"),
        )
    }
}
