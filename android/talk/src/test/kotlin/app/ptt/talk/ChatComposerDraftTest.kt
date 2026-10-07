package app.ptt.talk

import java.util.UUID
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class ChatComposerDraftTest {
    @Test fun draftPreservesReplyOrderAndIndividualCaptions() {
        val first = ChatStagedAttachment(fileName = "Photo.jpg", mimeType = "image/jpeg", byteCount = 1024, caption = "First")
        val second = ChatStagedAttachment(fileName = "Video.mp4", mimeType = "video/mp4", byteCount = 2048, caption = "Second")
        val reply = UUID.randomUUID()
        val original = ChatComposerDraft("Unsent text", reply, listOf(first, second)).validated()
        val reordered = original.copy(attachments = original.attachments.reversed()).validated()
        assertEquals(reply, reordered.replyToMessageId)
        assertEquals(listOf(second.id, first.id), reordered.attachments.map { it.id })
        assertEquals("Second", reordered.attachments.first().caption)
        assertEquals("Unsent text", reordered.text)
    }
    @Test fun limitsCountUtf8BytesAndRejectDuplicateIds() {
        val item = ChatStagedAttachment(fileName = "a", mimeType = "image/jpeg", byteCount = 1)
        assertThrows(IllegalArgumentException::class.java) { ChatComposerDraft(attachments = listOf(item, item)).validated() }
        assertThrows(IllegalArgumentException::class.java) { ChatComposerDraft(text = "😀".repeat(1025)).validated() }
        assertThrows(IllegalArgumentException::class.java) { ChatComposerDraft(attachments = listOf(item.copy(byteCount = 25 * 1024 * 1024 + 1))).validated() }
        assertThrows(IllegalArgumentException::class.java) { ChatComposerDraft(attachments = List(11) { item.copy(id = UUID.randomUUID()) }).validated() }
        assertEquals(10, ChatComposerDraft(attachments = List(10) { item.copy(id = UUID.randomUUID(), caption = "😀".repeat(1024)) }).validated().attachments.size)
    }
}
