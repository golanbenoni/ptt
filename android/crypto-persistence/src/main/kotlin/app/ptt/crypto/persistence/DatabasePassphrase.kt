package app.ptt.crypto.persistence

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keeps the random SQLCipher passphrase encrypted by a non-exportable Android Keystore key. */
internal object DatabasePassphrase {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ptt-signal-store-v1"
    private const val PREFS = "ptt-crypto-bootstrap-v1"
    private const val CIPHERTEXT = "wrapped-passphrase"
    private const val IV = "wrapped-passphrase-iv"

    @Synchronized
    fun loadOrCreate(context: Context): ByteArray {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val ciphertext = preferences.getString(CIPHERTEXT, null)?.decodeBase64()
        val iv = preferences.getString(IV, null)?.decodeBase64()
        val key = getOrCreateKey()

        if (ciphertext != null && iv != null) {
            return Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
                doFinal(ciphertext)
            }
        }

        check(ciphertext == null && iv == null) { "incomplete encrypted database key" }
        val passphrase = ByteArray(32).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val wrapped = cipher.doFinal(passphrase)
        check(
            preferences.edit()
                .putString(CIPHERTEXT, wrapped.encodeBase64())
                .putString(IV, cipher.iv.encodeBase64())
                .commit()
        ) { "could not persist encrypted database key" }
        return passphrase
    }

    private fun getOrCreateKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
    }

    private fun ByteArray.encodeBase64(): String =
        android.util.Base64.encodeToString(this, android.util.Base64.NO_WRAP)

    private fun String.decodeBase64(): ByteArray =
        android.util.Base64.decode(this, android.util.Base64.NO_WRAP)
}
