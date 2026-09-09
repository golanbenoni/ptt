package app.ptt.talk

import java.time.Instant
import java.util.UUID

internal enum class CallTimelineEventKind(val wire: String) {
    STARTED("started"),
    ANSWERED("answered"),
    PARTICIPANTS_CHANGED("participants_changed"),
    ENDED("ended"),
}

/**
 * A structured call event carried inside the existing pairwise-encrypted chat
 * envelope. The relay only sees ciphertext and the event follows the
 * conversation's normal retention and device-linking rules.
 */
internal data class EncryptedCallTimelineEvent(
    val callId: UUID,
    val kind: CallTimelineEventKind,
    val startedAt: Instant,
    val durationMs: Long = 0,
    val participantCount: Int,
    val endReason: String = "",
)

internal data class EncryptedCallHistoryItem(
    val callId: UUID,
    val channelId: UUID,
    val startedAt: Instant,
    val endedAt: Instant?,
    val durationMs: Long,
    val participantCount: Int,
    val endReason: String,
    val outgoing: Boolean,
    val answeredOnThisAccount: Boolean,
) {
    val missed: Boolean get() = endReason == "missed" && !answeredOnThisAccount
}

internal object EncryptedCallTimelineCodec {
    private const val PREFIX = "ptt-call-event:v1"
    private const val MAX_DURATION_MS = 8 * 60 * 60 * 1_000L
    private val reasonPattern = Regex("[a-z0-9_]{0,32}")

    fun encode(event: EncryptedCallTimelineEvent): String {
        validate(event)
        return listOf(
            PREFIX,
            event.kind.wire,
            event.callId.toString().lowercase(),
            event.startedAt.toEpochMilli().toString(),
            event.durationMs.toString(),
            event.participantCount.toString(),
            event.endReason.ifBlank { "-" },
        ).joinToString("|")
    }

    fun decode(value: String): EncryptedCallTimelineEvent? {
        if (!value.startsWith("$PREFIX|")) return null
        val fields = value.split('|')
        require(fields.size == 7 && fields[0] == PREFIX)
        val event = EncryptedCallTimelineEvent(
            callId = UUID.fromString(fields[2]),
            kind = CallTimelineEventKind.entries.single { it.wire == fields[1] },
            startedAt = Instant.ofEpochMilli(fields[3].toLong()),
            durationMs = fields[4].toLong(),
            participantCount = fields[5].toInt(),
            endReason = fields[6].takeUnless { it == "-" }.orEmpty(),
        )
        validate(event)
        require(fields[2] == event.callId.toString().lowercase())
        return event
    }

    fun history(messages: Collection<ChatMessage>, localAci: String): List<EncryptedCallHistoryItem> =
        messages.mapNotNull { message ->
            runCatching { decode(message.text) }.getOrNull()?.let { event -> message to event }
        }.groupBy { it.second.callId }.mapNotNull { (callId, entries) ->
            val ordered = entries.sortedBy { it.first.sentAt }
            val first = ordered.firstOrNull() ?: return@mapNotNull null
            val latest = ordered.last()
            val started = ordered.firstOrNull { it.second.kind == CallTimelineEventKind.STARTED } ?: first
            val ended = ordered.lastOrNull { it.second.kind == CallTimelineEventKind.ENDED }
            EncryptedCallHistoryItem(
                callId = callId,
                channelId = latest.first.channelId,
                startedAt = started.second.startedAt,
                endedAt = ended?.first?.sentAt,
                durationMs = ended?.second?.durationMs ?: latest.second.durationMs,
                participantCount = ordered.maxOf { it.second.participantCount },
                endReason = ended?.second?.endReason.orEmpty(),
                outgoing = started.first.senderAci.equals(localAci, true),
                answeredOnThisAccount = ordered.any {
                    it.second.kind == CallTimelineEventKind.ANSWERED && it.first.senderAci.equals(localAci, true)
                },
            )
        }.sortedByDescending { it.startedAt }

    private fun validate(event: EncryptedCallTimelineEvent) {
        require(event.startedAt.toEpochMilli() >= 0)
        require(event.durationMs in 0..MAX_DURATION_MS)
        require(event.participantCount in 1..8)
        require(reasonPattern.matches(event.endReason))
        require(event.kind == CallTimelineEventKind.ENDED || event.endReason.isEmpty())
    }
}
