package app.ptt.talk

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal data class ChatStagedAttachment(
    val id: UUID = UUID.randomUUID(), val fileName: String, val mimeType: String,
    val byteCount: Int, val caption: String = "",
)

internal data class ChatComposerDraft(
    val text: String = "", val replyToMessageId: UUID? = null,
    val attachments: List<ChatStagedAttachment> = emptyList(),
) {
    fun validated(): ChatComposerDraft = apply {
        require(text.toByteArray(Charsets.UTF_8).size <= 4096)
        require(attachments.size <= 10 && attachments.map { it.id }.distinct().size == attachments.size)
        require(attachments.all { it.byteCount in 1..(25 * 1024 * 1024) && it.caption.toByteArray(Charsets.UTF_8).size <= 4096 })
    }
    fun encode(): ByteArray {
        validated()
        return JSONObject().put("text", text).put("replyToMessageId", replyToMessageId?.toString())
            .put("attachments", JSONArray().apply { attachments.forEach {
                put(JSONObject().put("id", it.id.toString()).put("fileName", it.fileName)
                    .put("mimeType", it.mimeType).put("byteCount", it.byteCount).put("caption", it.caption))
            } }).toString().toByteArray(Charsets.UTF_8)
    }
    companion object {
        fun decode(data: ByteArray): ChatComposerDraft {
            val json = JSONObject(data.toString(Charsets.UTF_8))
            val items = json.optJSONArray("attachments") ?: JSONArray()
            return ChatComposerDraft(json.optString("text"), json.optString("replyToMessageId").takeIf { it.isNotEmpty() }?.let(UUID::fromString),
                (0 until items.length()).map { index -> items.getJSONObject(index).let {
                    ChatStagedAttachment(UUID.fromString(it.getString("id")), it.getString("fileName"), it.getString("mimeType"), it.getInt("byteCount"), it.optString("caption"))
                } }).validated()
        }
    }
}
