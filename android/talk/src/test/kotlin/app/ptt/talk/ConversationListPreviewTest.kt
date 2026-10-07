package app.ptt.talk

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class ConversationListPreviewTest {
    @Test
    fun draftLabelAppearsExactlyOnce() {
        assertEquals(
            "Draft: Meet at 10",
            conversationListPreview(
                preview = "Meet at 10",
                hasDraft = true,
                isSearchMatch = false,
            ),
        )
    }

    @Test
    fun searchMatchTakesPriorityOverDraftLabel() {
        assertEquals(
            "Match: deployment notes",
            conversationListPreview(
                preview = "Match: deployment notes",
                hasDraft = true,
                isSearchMatch = true,
            ),
        )
    }

    @Test
    fun ordinaryPreviewIsUnchanged() {
        assertEquals(
            "Voice message",
            conversationListPreview(
                preview = "Voice message",
                hasDraft = false,
                isSearchMatch = false,
            ),
        )
    }

    @Test
    fun timestampUsesTimeForTodayAndDateForOlderMessages() {
        val zone = ZoneId.of("UTC")
        val now = ZonedDateTime.parse("2026-09-25T15:00:00Z")

        assertEquals(
            "10:05\u202fAM",
            conversationListTimestamp(
                at = Instant.parse("2026-09-25T10:05:00Z"),
                now = now,
                zoneId = zone,
                locale = Locale.US,
            ),
        )
        assertEquals(
            "9/24/26",
            conversationListTimestamp(
                at = Instant.parse("2026-09-24T23:55:00Z"),
                now = now,
                zoneId = zone,
                locale = Locale.US,
            ),
        )
        assertEquals("", conversationListTimestamp(null, now, zone, Locale.US))
    }
}
