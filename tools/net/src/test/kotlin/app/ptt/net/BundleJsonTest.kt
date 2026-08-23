package app.ptt.net

import app.ptt.crypto.Aci
import app.ptt.crypto.PreKeyBundleDto
import java.util.UUID
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class BundleJsonTest {
    @Test
    fun roundTrip() {
        val dto =
            PreKeyBundleDto(
                aci = Aci(UUID.fromString("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")),
                deviceId = 1,
                registrationId = 9,
                identityKey = byteArrayOf(5, 1, 2, 3),
                signedPreKeyId = 1,
                signedPreKey = byteArrayOf(5, 4, 5, 6),
                signedPreKeySig = ByteArray(64) { it.toByte() },
                preKeyId = 2,
                preKey = byteArrayOf(5, 7, 8, 9),
                kyberPreKeyId = 1,
                kyberPreKey = ByteArray(32) { 1 },
                kyberPreKeySig = ByteArray(64) { 2 },
            )
        val parsed = BundleJson.fromJson(BundleJson.toJson(dto))
        assertEquals(dto.aci.uuid, parsed.aci.uuid)
        assertArrayEquals(dto.identityKey, parsed.identityKey)
        assertEquals(2, parsed.preKeyId)
    }

    @Test
    fun acceptsEscapedSlashesFromSwiftJsonEncoder() {
        val identity = "BT/eekN3hZ5FbTd17mQ+WUMi63mKBPd97XuDkGVKO+pY"
        val json =
            """{"aci":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","deviceId":1,"registrationId":1,""" +
                """"identityKey":"BT\/eekN3hZ5FbTd17mQ+WUMi63mKBPd97XuDkGVKO+pY",""" +
                """"signedPreKeyId":1,"signedPreKey":"AAAA","signedPreKeySig":"AAAA",""" +
                """"kyberPreKeyId":1,"kyberPreKey":"AAAA","kyberPreKeySig":"AAAA"}"""
        val parsed = BundleJson.fromJson(json)
        assertArrayEquals(java.util.Base64.getDecoder().decode(identity), parsed.identityKey)
    }
}
