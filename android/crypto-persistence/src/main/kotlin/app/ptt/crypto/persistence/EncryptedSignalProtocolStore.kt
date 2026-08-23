package app.ptt.crypto.persistence

import android.content.Context
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import java.io.Closeable
import java.util.UUID
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.ReusedBaseKeyException
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.groups.state.SenderKeyRecord
import org.signal.libsignal.protocol.state.IdentityKeyStore
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SignalProtocolStore
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * Durable libsignal state. The complete database is SQLCipher-encrypted and its random passphrase
 * is wrapped by Android Keystore. All returned records are reconstructed from serialized copies.
 */
class EncryptedSignalProtocolStore private constructor(
    private val helper: SupportSQLiteOpenHelper,
) : SignalProtocolStore, Closeable {
    private val db: SupportSQLiteDatabase
        get() = helper.writableDatabase

    override fun close() = helper.close()

    override fun getIdentityKeyPair(): IdentityKeyPair =
        IdentityKeyPair(requireState(LOCAL_IDENTITY))

    override fun getLocalRegistrationId(): Int =
        requireState(LOCAL_REGISTRATION).decodeToString().toInt()

    @Synchronized
    override fun saveIdentity(
        address: SignalProtocolAddress,
        identityKey: IdentityKey,
    ): IdentityKeyStore.IdentityChange {
        val previous = identityBytes(address)
        db.execSQL(
            "INSERT OR REPLACE INTO remote_identities(name, device_id, record) VALUES (?, ?, ?)",
            arrayOf(address.name, address.deviceId, identityKey.serialize()),
        )
        return if (previous != null && !previous.contentEquals(identityKey.serialize())) {
            IdentityKeyStore.IdentityChange.REPLACED_EXISTING
        } else {
            IdentityKeyStore.IdentityChange.NEW_OR_UNCHANGED
        }
    }

    override fun isTrustedIdentity(
        address: SignalProtocolAddress,
        identityKey: IdentityKey,
        direction: IdentityKeyStore.Direction,
    ): Boolean = identityBytes(address)?.contentEquals(identityKey.serialize()) ?: true

    override fun getIdentity(address: SignalProtocolAddress): IdentityKey? =
        identityBytes(address)?.let(::IdentityKey)

    override fun loadPreKey(preKeyId: Int): PreKeyRecord =
        PreKeyRecord(requireRecord("prekeys", preKeyId, "prekey"))

    override fun storePreKey(preKeyId: Int, record: PreKeyRecord) =
        putRecord("prekeys", preKeyId, record.serialize())

    override fun containsPreKey(preKeyId: Int): Boolean = containsRecord("prekeys", preKeyId)

    override fun removePreKey(preKeyId: Int) = removeRecord("prekeys", preKeyId)

    override fun loadSignedPreKey(signedPreKeyId: Int): SignedPreKeyRecord =
        SignedPreKeyRecord(requireRecord("signed_prekeys", signedPreKeyId, "signed prekey"))

    override fun loadSignedPreKeys(): List<SignedPreKeyRecord> =
        allRecords("signed_prekeys").map(::SignedPreKeyRecord)

    override fun storeSignedPreKey(signedPreKeyId: Int, record: SignedPreKeyRecord) =
        putRecord("signed_prekeys", signedPreKeyId, record.serialize())

    override fun containsSignedPreKey(signedPreKeyId: Int): Boolean =
        containsRecord("signed_prekeys", signedPreKeyId)

    override fun removeSignedPreKey(signedPreKeyId: Int) =
        removeRecord("signed_prekeys", signedPreKeyId)

    override fun loadKyberPreKey(kyberPreKeyId: Int): KyberPreKeyRecord =
        KyberPreKeyRecord(requireRecord("kyber_prekeys", kyberPreKeyId, "Kyber prekey"))

    override fun loadKyberPreKeys(): List<KyberPreKeyRecord> =
        allRecords("kyber_prekeys").map(::KyberPreKeyRecord)

    override fun storeKyberPreKey(kyberPreKeyId: Int, record: KyberPreKeyRecord) =
        putRecord("kyber_prekeys", kyberPreKeyId, record.serialize())

    override fun containsKyberPreKey(kyberPreKeyId: Int): Boolean =
        containsRecord("kyber_prekeys", kyberPreKeyId)

    @Synchronized
    override fun markKyberPreKeyUsed(
        kyberPreKeyId: Int,
        signedPreKeyId: Int,
        baseKey: ECPublicKey,
    ) {
        if (!containsKyberPreKey(kyberPreKeyId)) {
            throw InvalidKeyIdException("No such KyberPreKeyRecord: $kyberPreKeyId")
        }
        val statement =
            db.compileStatement(
                "INSERT OR IGNORE INTO kyber_base_keys(kyber_id, signed_id, base_key) VALUES (?, ?, ?)",
            )
        statement.bindLong(1, kyberPreKeyId.toLong())
        statement.bindLong(2, signedPreKeyId.toLong())
        statement.bindBlob(3, baseKey.serialize())
        if (statement.executeInsert() == -1L) throw ReusedBaseKeyException()
    }

    override fun loadSession(address: SignalProtocolAddress): SessionRecord? =
        addressRecord("sessions", address)?.let(::SessionRecord)

    override fun loadExistingSessions(addresses: List<SignalProtocolAddress>): List<SessionRecord> =
        addresses.map { address ->
            addressRecord("sessions", address)?.let(::SessionRecord)
                ?: throw NoSessionException(address, "no session for $address")
        }

    override fun getSubDeviceSessions(name: String): List<Int> {
        db.query(
            "SELECT device_id FROM sessions WHERE name = ? AND device_id <> 1 ORDER BY device_id",
            arrayOf(name),
        ).use { cursor ->
            return buildList {
                while (cursor.moveToNext()) add(cursor.getInt(0))
            }
        }
    }

    override fun storeSession(address: SignalProtocolAddress, record: SessionRecord) =
        putAddressRecord("sessions", address, record.serialize())

    override fun containsSession(address: SignalProtocolAddress): Boolean =
        addressRecord("sessions", address) != null

    override fun deleteSession(address: SignalProtocolAddress) {
        db.execSQL(
            "DELETE FROM sessions WHERE name = ? AND device_id = ?",
            arrayOf(address.name, address.deviceId),
        )
    }

    override fun deleteAllSessions(name: String) {
        db.execSQL("DELETE FROM sessions WHERE name = ?", arrayOf(name))
    }

    override fun storeSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
    ) {
        db.execSQL(
            """INSERT OR REPLACE INTO sender_keys(name, device_id, distribution_id, record)
               VALUES (?, ?, ?, ?)""",
            arrayOf(sender.name, sender.deviceId, distributionId.toString(), record.serialize()),
        )
    }

    override fun loadSenderKey(
        sender: SignalProtocolAddress,
        distributionId: UUID,
    ): SenderKeyRecord? {
        db.query(
            """SELECT record FROM sender_keys
               WHERE name = ? AND device_id = ? AND distribution_id = ?""",
            arrayOf(sender.name, sender.deviceId, distributionId.toString()),
        ).use { cursor ->
            return if (cursor.moveToFirst()) SenderKeyRecord(cursor.getBlob(0)) else null
        }
    }

    /** Atomically consumes a counter before returning it, preventing nonce reuse after a crash. */
    @Synchronized
    fun nextMediaCounter(streamKey: String): Long {
        require(streamKey.isNotBlank()) { "stream key is required" }
        db.beginTransaction()
        try {
            val current =
                db.query("SELECT next_value FROM media_counters WHERE stream_key = ?", arrayOf(streamKey))
                    .use { if (it.moveToFirst()) it.getLong(0) else 0L }
            check(current >= 0 && current < Long.MAX_VALUE) { "media counter exhausted" }
            db.execSQL(
                "INSERT OR REPLACE INTO media_counters(stream_key, next_value) VALUES (?, ?)",
                arrayOf<Any>(streamKey, current + 1),
            )
            db.setTransactionSuccessful()
            return current
        } finally {
            db.endTransaction()
        }
    }

    private fun requireState(key: String): ByteArray =
        db.query("SELECT value FROM local_state WHERE key = ?", arrayOf(key)).use { cursor ->
            check(cursor.moveToFirst()) { "missing local cryptographic state: $key" }
            cursor.getBlob(0)
        }

    private fun identityBytes(address: SignalProtocolAddress): ByteArray? =
        db.query(
            "SELECT record FROM remote_identities WHERE name = ? AND device_id = ?",
            arrayOf(address.name, address.deviceId),
        ).use { if (it.moveToFirst()) it.getBlob(0) else null }

    private fun requireRecord(table: String, id: Int, description: String): ByteArray =
        db.query("SELECT record FROM $table WHERE id = ?", arrayOf(id)).use {
            if (!it.moveToFirst()) throw InvalidKeyIdException("No such $description: $id")
            it.getBlob(0)
        }

    private fun allRecords(table: String): List<ByteArray> =
        db.query("SELECT record FROM $table ORDER BY id").use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getBlob(0)) }
        }

    private fun putRecord(table: String, id: Int, record: ByteArray) {
        db.execSQL("INSERT OR REPLACE INTO $table(id, record) VALUES (?, ?)", arrayOf(id, record))
    }

    private fun containsRecord(table: String, id: Int): Boolean =
        db.query("SELECT 1 FROM $table WHERE id = ?", arrayOf(id)).use { it.moveToFirst() }

    private fun removeRecord(table: String, id: Int) {
        db.execSQL("DELETE FROM $table WHERE id = ?", arrayOf(id))
    }

    private fun addressRecord(table: String, address: SignalProtocolAddress): ByteArray? =
        db.query(
            "SELECT record FROM $table WHERE name = ? AND device_id = ?",
            arrayOf(address.name, address.deviceId),
        ).use { if (it.moveToFirst()) it.getBlob(0) else null }

    private fun putAddressRecord(
        table: String,
        address: SignalProtocolAddress,
        record: ByteArray,
    ) {
        db.execSQL(
            "INSERT OR REPLACE INTO $table(name, device_id, record) VALUES (?, ?, ?)",
            arrayOf(address.name, address.deviceId, record),
        )
    }

    companion object {
        private const val DATABASE_NAME = "signal-protocol-v1.db"
        private const val DATABASE_VERSION = 1
        private const val LOCAL_IDENTITY = "identity-key-pair"
        private const val LOCAL_REGISTRATION = "registration-id"

        init {
            System.loadLibrary("sqlcipher")
        }

        /** Opens an existing store or initializes a new one with the supplied local identity. */
        fun open(
            context: Context,
            initialIdentity: IdentityKeyPair? = null,
            initialRegistrationId: Int? = null,
        ): EncryptedSignalProtocolStore {
            require((initialIdentity == null) == (initialRegistrationId == null)) {
                "identity and registration ID must be supplied together"
            }
            initialRegistrationId?.let { require(it in 1..16380) { "invalid registration ID" } }
            val passphrase = DatabasePassphrase.loadOrCreate(context.applicationContext)
            val configuration =
                SupportSQLiteOpenHelper.Configuration.builder(context.applicationContext)
                    .name(DATABASE_NAME)
                    .callback(StoreCallback())
                    .build()
            // The helper needs the passphrase for the lifetime of this open database. Give it a
            // private copy, then erase the bootstrap copy returned from Keystore unwrap.
            val helper = SupportOpenHelperFactory(passphrase.copyOf(), null, false).create(configuration)
            passphrase.fill(0)
            val result = EncryptedSignalProtocolStore(helper)
            result.initializeOrVerify(initialIdentity, initialRegistrationId)
            return result
        }
    }

    private fun initializeOrVerify(identity: IdentityKeyPair?, registrationId: Int?) {
        val exists =
            db.query("SELECT 1 FROM local_state WHERE key = ?", arrayOf(LOCAL_IDENTITY)).use {
                it.moveToFirst()
            }
        if (!exists) {
            check(identity != null && registrationId != null) {
                "new encrypted store requires an identity and registration ID"
            }
            db.beginTransaction()
            try {
                db.execSQL(
                    "INSERT INTO local_state(key, value) VALUES (?, ?)",
                    arrayOf(LOCAL_IDENTITY, identity.serialize()),
                )
                db.execSQL(
                    "INSERT INTO local_state(key, value) VALUES (?, ?)",
                    arrayOf(LOCAL_REGISTRATION, registrationId.toString().encodeToByteArray()),
                )
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        } else if (identity != null) {
            check(getIdentityKeyPair().serialize().contentEquals(identity.serialize())) {
                "refusing to replace an existing device identity"
            }
            check(localRegistrationId == registrationId) {
                "registration ID does not match existing device state"
            }
        }
    }

    private class StoreCallback : SupportSQLiteOpenHelper.Callback(DATABASE_VERSION) {
        override fun onCreate(db: SupportSQLiteDatabase) {
            db.execSQL("CREATE TABLE local_state(key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            db.execSQL(
                """CREATE TABLE remote_identities(
                   name TEXT NOT NULL, device_id INTEGER NOT NULL CHECK(device_id BETWEEN 1 AND 2),
                   record BLOB NOT NULL, PRIMARY KEY(name, device_id))""",
            )
            listOf("prekeys", "signed_prekeys", "kyber_prekeys").forEach {
                db.execSQL("CREATE TABLE $it(id INTEGER PRIMARY KEY, record BLOB NOT NULL)")
            }
            db.execSQL(
                """CREATE TABLE sessions(
                   name TEXT NOT NULL, device_id INTEGER NOT NULL CHECK(device_id BETWEEN 1 AND 2),
                   record BLOB NOT NULL, PRIMARY KEY(name, device_id))""",
            )
            db.execSQL(
                """CREATE TABLE sender_keys(
                   name TEXT NOT NULL, device_id INTEGER NOT NULL CHECK(device_id BETWEEN 1 AND 2),
                   distribution_id TEXT NOT NULL, record BLOB NOT NULL,
                   PRIMARY KEY(name, device_id, distribution_id))""",
            )
            db.execSQL(
                """CREATE TABLE kyber_base_keys(
                   kyber_id INTEGER NOT NULL, signed_id INTEGER NOT NULL, base_key BLOB NOT NULL,
                   PRIMARY KEY(kyber_id, signed_id, base_key),
                   FOREIGN KEY(kyber_id) REFERENCES kyber_prekeys(id) ON DELETE CASCADE)""",
            )
            db.execSQL(
                """CREATE TABLE media_counters(
                   stream_key TEXT PRIMARY KEY, next_value INTEGER NOT NULL CHECK(next_value >= 0))""",
            )
        }

        override fun onConfigure(db: SupportSQLiteDatabase) {
            db.setForeignKeyConstraintsEnabled(true)
        }

        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {
            error("unsupported crypto database migration $oldVersion -> $newVersion")
        }
    }
}
