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

data class EncryptedHistoryRecord(
    val talkId: String,
    val channelId: String,
    val membershipEpoch: Int,
    val mediaKid: String,
    val baseKey: ByteArray,
    val senderAci: String,
    val senderDeviceId: Int,
    val announcedAtMs: Long,
    val objectId: String?,
    val startedAtMs: Long?,
    val durationMs: Int?,
    val expiresAtMs: Long?,
    val ciphertext: ByteArray?,
    val isSos: Boolean = false,
)

data class EncryptedChatRecord(
    val messageId: String,
    val channelId: String,
    val senderAci: String,
    val senderDeviceId: Int,
    val sentAtMs: Long,
    val expiresAtMs: Long,
    val payload: ByteArray,
    val attachmentCiphertext: ByteArray?,
)

data class EncryptedChatEventRecord(
    val eventId: String,
    val channelId: String,
    val senderAci: String,
    val senderDeviceId: Int,
    val sentAtMs: Long,
    val expiresAtMs: Long,
    val payload: ByteArray,
)

data class EncryptedChatOutboxRecord(
    val eventId: String,
    val channelId: String,
    val membershipEpoch: Int,
    val senderAci: String,
    val senderDeviceId: Int,
    val sentAtMs: Long,
    val expiresAtMs: Long,
    val payload: ByteArray,
    val recipients: ByteArray,
    val state: String,
    val attemptCount: Int,
    val lastErrorCode: String?,
)

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

    @Synchronized
    fun applicationState(key: String): ByteArray? {
        require(key.matches(Regex("[a-z0-9-]{1,64}"))) { "invalid application state key" }
        return db.query("SELECT value FROM local_state WHERE key = ?", arrayOf("application/$key")).use {
            if (it.moveToFirst()) it.getBlob(0) else null
        }
    }

    @Synchronized
    fun putApplicationState(key: String, value: ByteArray) {
        require(key.matches(Regex("[a-z0-9-]{1,64}"))) { "invalid application state key" }
        require(value.size <= 65_536) { "application state value is too large" }
        db.execSQL(
            "INSERT OR REPLACE INTO local_state(key, value) VALUES (?, ?)",
            arrayOf("application/$key", value.copyOf()),
        )
    }

    /** Saves the per-device media epoch before its mailbox envelope is acknowledged. */
    @Synchronized
    fun putHistoryEpoch(record: EncryptedHistoryRecord) {
        require(record.talkId.isNotBlank() && record.channelId.isNotBlank())
        require(record.membershipEpoch > 0 && record.mediaKid.toULong() > 0uL)
        require(record.baseKey.size == 32 && record.senderDeviceId in 1..2)
        val existing = historyRecord(record.talkId)
        if (existing != null) {
            check(existing.channelId == record.channelId &&
                existing.membershipEpoch == record.membershipEpoch &&
                existing.mediaKid == record.mediaKid &&
                existing.baseKey.contentEquals(record.baseKey) &&
                existing.senderAci == record.senderAci &&
                existing.senderDeviceId == record.senderDeviceId &&
                existing.isSos == record.isSos
            ) { "talk ID was reused with different history key metadata" }
            return
        }
        db.execSQL(
            """INSERT INTO encrypted_history(
               talk_id, channel_id, membership_epoch, media_kid, base_key, sender_aci,
               sender_device_id, announced_at_ms, is_sos) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            arrayOf(
                record.talkId,
                record.channelId,
                record.membershipEpoch,
                record.mediaKid,
                record.baseKey.copyOf(),
                record.senderAci,
                record.senderDeviceId,
                record.announcedAtMs,
                if (record.isSos) 1 else 0,
            ),
        )
    }

    @Synchronized
    fun completeHistory(
        talkId: String,
        objectId: String,
        startedAtMs: Long,
        durationMs: Int,
        expiresAtMs: Long,
        ciphertext: ByteArray,
    ) {
        require(talkId.isNotBlank() && objectId.isNotBlank())
        require(startedAtMs > 0 && durationMs in 1..30_000 && expiresAtMs > startedAtMs)
        require(ciphertext.isNotEmpty() && ciphertext.size <= 16 * 1024 * 1024)
        val statement = db.compileStatement(
            """UPDATE encrypted_history SET object_id = ?, started_at_ms = ?, duration_ms = ?,
               expires_at_ms = ?, ciphertext = ? WHERE talk_id = ?""",
        )
        statement.bindString(1, objectId)
        statement.bindLong(2, startedAtMs)
        statement.bindLong(3, durationMs.toLong())
        statement.bindLong(4, expiresAtMs)
        statement.bindBlob(5, ciphertext.copyOf())
        statement.bindString(6, talkId)
        check(statement.executeUpdateDelete() == 1) { "missing history epoch for talk" }
        pruneHistory(System.currentTimeMillis())
    }

    @Synchronized
    fun historyRecord(talkId: String): EncryptedHistoryRecord? =
        db.query(
            """SELECT talk_id, channel_id, membership_epoch, media_kid, base_key, sender_aci,
               sender_device_id, announced_at_ms, object_id, started_at_ms, duration_ms,
               expires_at_ms, ciphertext, is_sos FROM encrypted_history WHERE talk_id = ?""",
            arrayOf(talkId),
        ).use { if (it.moveToFirst()) readHistoryRecord(it) else null }

    @Synchronized
    fun historyRecords(channelId: String, includePending: Boolean = false): List<EncryptedHistoryRecord> {
        val pendingClause = if (includePending) "" else "AND object_id IS NOT NULL"
        return db.query(
            """SELECT talk_id, channel_id, membership_epoch, media_kid, base_key, sender_aci,
               sender_device_id, announced_at_ms, object_id, started_at_ms, duration_ms,
               expires_at_ms, ciphertext, is_sos FROM encrypted_history
               WHERE channel_id = ? $pendingClause ORDER BY COALESCE(started_at_ms, announced_at_ms) DESC""",
            arrayOf(channelId),
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(readHistoryRecord(cursor)) } }
    }

    @Synchronized
    fun pruneHistory(nowMs: Long, maximumBytes: Long = 1_000_000_000L) {
        require(nowMs > 0 && maximumBytes > 0)
        db.execSQL("DELETE FROM encrypted_history WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?", arrayOf(nowMs))
        var total = db.query("SELECT COALESCE(SUM(length(ciphertext)), 0) FROM encrypted_history").use {
            check(it.moveToFirst())
            it.getLong(0)
        }
        while (total > maximumBytes) {
            val removed = db.compileStatement(
                """DELETE FROM encrypted_history WHERE talk_id = (
                   SELECT talk_id FROM encrypted_history WHERE ciphertext IS NOT NULL
                   ORDER BY COALESCE(started_at_ms, announced_at_ms), talk_id LIMIT 1)""",
            ).executeUpdateDelete()
            if (removed == 0) break
            total = db.query("SELECT COALESCE(SUM(length(ciphertext)), 0) FROM encrypted_history").use {
                check(it.moveToFirst())
                it.getLong(0)
            }
        }
    }

    @Synchronized
    fun putChatRecord(record: EncryptedChatRecord) {
        require(record.messageId.isNotBlank() && record.channelId.isNotBlank() && record.senderAci.isNotBlank())
        require(record.senderDeviceId in 1..2 && record.sentAtMs > 0 && record.expiresAtMs > record.sentAtMs)
        require(record.payload.isNotEmpty() && record.payload.size <= 131_072)
        require(record.attachmentCiphertext == null || record.attachmentCiphertext.size <= 26 * 1024 * 1024)
        val existing = chatRecord(record.messageId)
        if (existing != null) {
            check(existing.channelId == record.channelId && existing.senderAci == record.senderAci &&
                existing.senderDeviceId == record.senderDeviceId && existing.payload.contentEquals(record.payload)) {
                "chat message ID was reused"
            }
            if (existing.attachmentCiphertext == null && record.attachmentCiphertext != null) {
                cacheChatAttachment(record.messageId, record.attachmentCiphertext)
            }
            return
        }
        db.execSQL(
            """INSERT INTO encrypted_chat(message_id,channel_id,sender_aci,sender_device_id,sent_at_ms,
               expires_at_ms,payload,attachment_ciphertext) VALUES(?,?,?,?,?,?,?,?)""",
            arrayOf(record.messageId, record.channelId, record.senderAci, record.senderDeviceId,
                record.sentAtMs, record.expiresAtMs, record.payload.copyOf(), record.attachmentCiphertext?.copyOf()),
        )
        pruneChat(System.currentTimeMillis())
    }

    @Synchronized
    fun chatRecords(channelId: String): List<EncryptedChatRecord> =
        db.query(
            """SELECT message_id,channel_id,sender_aci,sender_device_id,sent_at_ms,expires_at_ms,
               payload,attachment_ciphertext FROM encrypted_chat
               WHERE channel_id=? AND expires_at_ms>? ORDER BY sent_at_ms,message_id""",
            arrayOf(channelId, System.currentTimeMillis().toString()),
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(readChatRecord(cursor)) } }

    @Synchronized
    fun chatRecord(messageId: String): EncryptedChatRecord? =
        db.query(
            """SELECT message_id,channel_id,sender_aci,sender_device_id,sent_at_ms,expires_at_ms,
               payload,attachment_ciphertext FROM encrypted_chat WHERE message_id=?""",
            arrayOf(messageId),
        ).use { if (it.moveToFirst()) readChatRecord(it) else null }

    @Synchronized
    fun cacheChatAttachment(messageId: String, ciphertext: ByteArray) {
        require(ciphertext.isNotEmpty() && ciphertext.size <= 26 * 1024 * 1024)
        val statement = db.compileStatement(
            "UPDATE encrypted_chat SET attachment_ciphertext=? WHERE message_id=?",
        )
        statement.bindBlob(1, ciphertext.copyOf())
        statement.bindString(2, messageId)
        statement.executeUpdateDelete()
        pruneChat(System.currentTimeMillis())
    }

    @Synchronized
    fun putChatEvent(record: EncryptedChatEventRecord) {
        require(record.eventId.isNotBlank() && record.channelId.isNotBlank() && record.senderAci.isNotBlank())
        require(record.senderDeviceId in 1..2 && record.sentAtMs > 0 && record.expiresAtMs > record.sentAtMs)
        require(record.payload.isNotEmpty() && record.payload.size <= 131_072)
        val existing = chatEvent(record.eventId)
        if (existing != null) {
            check(existing.channelId == record.channelId && existing.senderAci == record.senderAci &&
                existing.senderDeviceId == record.senderDeviceId && existing.payload.contentEquals(record.payload)) {
                "chat event ID was reused"
            }
            return
        }
        db.execSQL(
            """INSERT INTO encrypted_chat_events(event_id,channel_id,sender_aci,sender_device_id,sent_at_ms,
               expires_at_ms,payload) VALUES(?,?,?,?,?,?,?)""",
            arrayOf(record.eventId, record.channelId, record.senderAci, record.senderDeviceId,
                record.sentAtMs, record.expiresAtMs, record.payload.copyOf()),
        )
        pruneChat(System.currentTimeMillis())
    }

    @Synchronized
    fun chatEvents(channelId: String): List<EncryptedChatEventRecord> =
        db.query(
            """SELECT event_id,channel_id,sender_aci,sender_device_id,sent_at_ms,expires_at_ms,payload
               FROM encrypted_chat_events WHERE channel_id=? AND expires_at_ms>?
               ORDER BY sent_at_ms,event_id""",
            arrayOf(channelId, System.currentTimeMillis().toString()),
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(readChatEvent(cursor)) } }

    @Synchronized
    fun chatEvent(eventId: String): EncryptedChatEventRecord? =
        db.query(
            """SELECT event_id,channel_id,sender_aci,sender_device_id,sent_at_ms,expires_at_ms,payload
               FROM encrypted_chat_events WHERE event_id=?""",
            arrayOf(eventId),
        ).use { if (it.moveToFirst()) readChatEvent(it) else null }

    @Synchronized
    fun putChatOutbox(record: EncryptedChatOutboxRecord) {
        require(record.eventId.isNotBlank() && record.channelId.isNotBlank() && record.senderAci.isNotBlank())
        require(record.membershipEpoch > 0 && record.senderDeviceId in 1..2)
        require(record.sentAtMs > 0 && record.expiresAtMs > record.sentAtMs)
        require(record.payload.isNotEmpty() && record.payload.size <= 131_072)
        require(record.recipients.size <= 128 * 131_200 && record.state in setOf("queued", "sending", "failed"))
        val existing = chatOutbox(record.eventId)
        if (existing != null) {
            check(existing.channelId == record.channelId && existing.payload.contentEquals(record.payload) &&
                existing.recipients.contentEquals(record.recipients)) { "chat outbox event ID was reused" }
            return
        }
        db.execSQL(
            """INSERT INTO chat_outbox(event_id,channel_id,membership_epoch,sender_aci,sender_device_id,
               sent_at_ms,expires_at_ms,payload,recipients,state,attempt_count,last_error_code)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            arrayOf(record.eventId, record.channelId, record.membershipEpoch, record.senderAci,
                record.senderDeviceId, record.sentAtMs, record.expiresAtMs, record.payload.copyOf(),
                record.recipients.copyOf(), record.state, record.attemptCount, record.lastErrorCode),
        )
    }

    @Synchronized
    fun chatOutbox(): List<EncryptedChatOutboxRecord> {
        db.execSQL("DELETE FROM chat_outbox WHERE expires_at_ms<=?", arrayOf(System.currentTimeMillis()))
        return db.query(
            """SELECT event_id,channel_id,membership_epoch,sender_aci,sender_device_id,sent_at_ms,
               expires_at_ms,payload,recipients,state,attempt_count,last_error_code
               FROM chat_outbox ORDER BY sent_at_ms,event_id""",
        ).use { cursor -> buildList { while (cursor.moveToNext()) add(readChatOutbox(cursor)) } }
    }

    @Synchronized
    fun chatOutbox(eventId: String): EncryptedChatOutboxRecord? =
        db.query(
            """SELECT event_id,channel_id,membership_epoch,sender_aci,sender_device_id,sent_at_ms,
               expires_at_ms,payload,recipients,state,attempt_count,last_error_code
               FROM chat_outbox WHERE event_id=?""",
            arrayOf(eventId),
        ).use { if (it.moveToFirst()) readChatOutbox(it) else null }

    @Synchronized
    fun markChatOutbox(eventId: String, state: String, errorCode: String? = null) {
        require(state in setOf("queued", "sending", "failed"))
        db.execSQL(
            """UPDATE chat_outbox SET state=?,attempt_count=attempt_count+CASE WHEN ?='sending' THEN 1 ELSE 0 END,
               last_error_code=? WHERE event_id=?""",
            arrayOf(state, state, errorCode, eventId),
        )
    }

    @Synchronized
    fun resolveChatOutboxRecipients(eventId: String, emptyRecipients: ByteArray, recipients: ByteArray) {
        require(recipients.isNotEmpty() && recipients.size <= 128 * 131_200)
        val statement = db.compileStatement(
            "UPDATE chat_outbox SET recipients=?,state='queued',last_error_code=NULL WHERE event_id=? AND recipients=?",
        )
        statement.bindBlob(1, recipients.copyOf())
        statement.bindString(2, eventId)
        statement.bindBlob(3, emptyRecipients.copyOf())
        val changed = statement.executeUpdateDelete()
        if (changed == 0) {
            val existing = requireNotNull(chatOutbox(eventId))
            check(existing.recipients.contentEquals(recipients)) { "chat outbox recipients already resolved differently" }
        }
    }

    @Synchronized
    fun removeChatOutbox(eventId: String) {
        db.execSQL("DELETE FROM chat_outbox WHERE event_id=?", arrayOf(eventId))
    }

    @Synchronized
    fun cancelChatSend(eventId: String) {
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM chat_outbox WHERE event_id=?", arrayOf(eventId))
            db.execSQL("DELETE FROM encrypted_chat_events WHERE event_id=?", arrayOf(eventId))
            db.execSQL("DELETE FROM encrypted_chat WHERE message_id=?", arrayOf(eventId))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    @Synchronized
    fun pruneChat(nowMs: Long, maximumBytes: Long = 1_000_000_000L) {
        db.execSQL("DELETE FROM encrypted_chat WHERE expires_at_ms<=?", arrayOf(nowMs))
        db.execSQL("DELETE FROM encrypted_chat_events WHERE expires_at_ms<=?", arrayOf(nowMs))
        var total = db.query(
            """SELECT
               (SELECT COALESCE(SUM(length(payload)+COALESCE(length(attachment_ciphertext),0)),0) FROM encrypted_chat) +
               (SELECT COALESCE(SUM(length(payload)),0) FROM encrypted_chat_events)""",
        ).use {
            check(it.moveToFirst()); it.getLong(0)
        }
        while (total > maximumBytes) {
            val oldest = db.query(
                """SELECT kind,id FROM (
                   SELECT 'message' AS kind,message_id AS id,sent_at_ms FROM encrypted_chat
                   UNION ALL SELECT 'event',event_id,sent_at_ms FROM encrypted_chat_events)
                   ORDER BY sent_at_ms,id LIMIT 1""",
            ).use { if (it.moveToFirst()) it.getString(0) to it.getString(1) else null }
            val removed = when (oldest?.first) {
                "message" -> db.compileStatement("DELETE FROM encrypted_chat WHERE message_id=?").run {
                    bindString(1, oldest.second); executeUpdateDelete()
                }
                "event" -> db.compileStatement("DELETE FROM encrypted_chat_events WHERE event_id=?").run {
                    bindString(1, oldest.second); executeUpdateDelete()
                }
                else -> 0
            }
            if (removed == 0) break
            total = db.query(
                """SELECT
                   (SELECT COALESCE(SUM(length(payload)+COALESCE(length(attachment_ciphertext),0)),0) FROM encrypted_chat) +
                   (SELECT COALESCE(SUM(length(payload)),0) FROM encrypted_chat_events)""",
            ).use {
                check(it.moveToFirst()); it.getLong(0)
            }
        }
    }

    private fun readChatRecord(cursor: android.database.Cursor): EncryptedChatRecord = EncryptedChatRecord(
        messageId = cursor.getString(0), channelId = cursor.getString(1), senderAci = cursor.getString(2),
        senderDeviceId = cursor.getInt(3), sentAtMs = cursor.getLong(4), expiresAtMs = cursor.getLong(5),
        payload = cursor.getBlob(6), attachmentCiphertext = if (cursor.isNull(7)) null else cursor.getBlob(7),
    )

    private fun readChatEvent(cursor: android.database.Cursor): EncryptedChatEventRecord = EncryptedChatEventRecord(
        eventId = cursor.getString(0), channelId = cursor.getString(1), senderAci = cursor.getString(2),
        senderDeviceId = cursor.getInt(3), sentAtMs = cursor.getLong(4), expiresAtMs = cursor.getLong(5),
        payload = cursor.getBlob(6),
    )

    private fun readChatOutbox(cursor: android.database.Cursor): EncryptedChatOutboxRecord = EncryptedChatOutboxRecord(
        eventId = cursor.getString(0), channelId = cursor.getString(1), membershipEpoch = cursor.getInt(2),
        senderAci = cursor.getString(3), senderDeviceId = cursor.getInt(4), sentAtMs = cursor.getLong(5),
        expiresAtMs = cursor.getLong(6), payload = cursor.getBlob(7), recipients = cursor.getBlob(8),
        state = cursor.getString(9), attemptCount = cursor.getInt(10),
        lastErrorCode = if (cursor.isNull(11)) null else cursor.getString(11),
    )

    private fun readHistoryRecord(cursor: android.database.Cursor): EncryptedHistoryRecord =
        EncryptedHistoryRecord(
            talkId = cursor.getString(0),
            channelId = cursor.getString(1),
            membershipEpoch = cursor.getInt(2),
            mediaKid = cursor.getString(3),
            baseKey = cursor.getBlob(4),
            senderAci = cursor.getString(5),
            senderDeviceId = cursor.getInt(6),
            announcedAtMs = cursor.getLong(7),
            objectId = if (cursor.isNull(8)) null else cursor.getString(8),
            startedAtMs = if (cursor.isNull(9)) null else cursor.getLong(9),
            durationMs = if (cursor.isNull(10)) null else cursor.getInt(10),
            expiresAtMs = if (cursor.isNull(11)) null else cursor.getLong(11),
            ciphertext = if (cursor.isNull(12)) null else cursor.getBlob(12),
            isSos = cursor.getInt(13) != 0,
        )

    /** Atomically allocates positive libsignal record IDs without reuse after a crash. */
    @Synchronized
    fun nextApplicationRecordId(name: String): Int {
        require(name.matches(Regex("[a-z0-9-]{1,48}"))) { "invalid record counter name" }
        val key = "application/id-$name"
        db.beginTransaction()
        try {
            val current =
                db.query("SELECT value FROM local_state WHERE key = ?", arrayOf(key)).use {
                    if (it.moveToFirst()) it.getBlob(0).decodeToString().toInt() else 1
                }
            check(current in 1 until Int.MAX_VALUE) { "record ID exhausted" }
            db.execSQL(
                "INSERT OR REPLACE INTO local_state(key, value) VALUES (?, ?)",
                arrayOf(key, (current + 1).toString().encodeToByteArray()),
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
        private const val DATABASE_VERSION = 6
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

        /**
         * Irreversibly removes the local Signal identity and sessions after the user starts the
         * server's admin-approved recovery flow. The server separately revokes the old devices.
         */
        fun resetLocalDeviceState(context: Context) {
            val app = context.applicationContext
            check(app.deleteDatabase(DATABASE_NAME) || !app.getDatabasePath(DATABASE_NAME).exists()) {
                "could not remove old encrypted device state"
            }
            DatabasePassphrase.delete(app)
        }

        fun resetForAccountRecovery(context: Context) = resetLocalDeviceState(context)
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
            createHistoryTable(db)
            createChatTable(db)
            createChatEventTable(db)
            createChatOutboxTable(db)
        }

        override fun onConfigure(db: SupportSQLiteDatabase) {
            db.setForeignKeyConstraintsEnabled(true)
        }

        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion == 1 && newVersion >= 2) {
                createHistoryTable(db)
            }
            if (oldVersion <= 2 && newVersion >= 3) {
                if (oldVersion == 2) db.execSQL("ALTER TABLE encrypted_history ADD COLUMN is_sos INTEGER NOT NULL DEFAULT 0 CHECK(is_sos IN (0,1))")
            }
            if (oldVersion <= 3 && newVersion >= 4) createChatTable(db)
            if (oldVersion <= 4 && newVersion >= 5) createChatEventTable(db)
            if (oldVersion <= 5 && newVersion >= 6) createChatOutboxTable(db)
            if (newVersion != DATABASE_VERSION) error("unsupported crypto database migration $oldVersion -> $newVersion")
        }

        private fun createHistoryTable(db: SupportSQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE encrypted_history(
                   talk_id TEXT PRIMARY KEY,
                   channel_id TEXT NOT NULL,
                   membership_epoch INTEGER NOT NULL CHECK(membership_epoch > 0),
                   media_kid TEXT NOT NULL,
                   base_key BLOB NOT NULL CHECK(length(base_key) = 32),
                   sender_aci TEXT NOT NULL,
                   sender_device_id INTEGER NOT NULL CHECK(sender_device_id BETWEEN 1 AND 2),
                   announced_at_ms INTEGER NOT NULL,
                   object_id TEXT UNIQUE,
                   started_at_ms INTEGER,
                   duration_ms INTEGER CHECK(duration_ms BETWEEN 1 AND 30000),
                   expires_at_ms INTEGER,
                   ciphertext BLOB,
                   is_sos INTEGER NOT NULL DEFAULT 0 CHECK(is_sos IN (0,1)))""",
            )
            db.execSQL(
                "CREATE INDEX encrypted_history_channel_time ON encrypted_history(channel_id, started_at_ms DESC)",
            )
        }

        private fun createChatTable(db: SupportSQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE encrypted_chat(
                   message_id TEXT PRIMARY KEY,
                   channel_id TEXT NOT NULL,
                   sender_aci TEXT NOT NULL,
                   sender_device_id INTEGER NOT NULL CHECK(sender_device_id BETWEEN 1 AND 2),
                   sent_at_ms INTEGER NOT NULL,
                   expires_at_ms INTEGER NOT NULL,
                   payload BLOB NOT NULL,
                   attachment_ciphertext BLOB)""",
            )
            db.execSQL("CREATE INDEX encrypted_chat_channel_time ON encrypted_chat(channel_id,sent_at_ms,message_id)")
        }

        private fun createChatEventTable(db: SupportSQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE encrypted_chat_events(
                   event_id TEXT PRIMARY KEY,
                   channel_id TEXT NOT NULL,
                   sender_aci TEXT NOT NULL,
                   sender_device_id INTEGER NOT NULL CHECK(sender_device_id BETWEEN 1 AND 2),
                   sent_at_ms INTEGER NOT NULL,
                   expires_at_ms INTEGER NOT NULL,
                   payload BLOB NOT NULL)""",
            )
            db.execSQL(
                "CREATE INDEX encrypted_chat_events_channel_time ON encrypted_chat_events(channel_id,sent_at_ms,event_id)",
            )
        }

        private fun createChatOutboxTable(db: SupportSQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE chat_outbox(
                   event_id TEXT PRIMARY KEY,
                   channel_id TEXT NOT NULL,
                   membership_epoch INTEGER NOT NULL CHECK(membership_epoch > 0),
                   sender_aci TEXT NOT NULL,
                   sender_device_id INTEGER NOT NULL CHECK(sender_device_id BETWEEN 1 AND 2),
                   sent_at_ms INTEGER NOT NULL,
                   expires_at_ms INTEGER NOT NULL,
                   payload BLOB NOT NULL,
                   recipients BLOB NOT NULL,
                   state TEXT NOT NULL CHECK(state IN ('queued','sending','failed')),
                   attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
                   last_error_code TEXT)""",
            )
            db.execSQL("CREATE INDEX chat_outbox_time ON chat_outbox(sent_at_ms,event_id)")
        }
    }
}
