package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.graphics.BitmapFactory
import android.text.Editable
import android.text.TextWatcher
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.concurrent.thread

internal class StagedMediaDialog(
    private val activity: Activity,
    private val client: EncryptedChatClient,
    private val channel: ChannelSummary,
    private val onSend: (() -> Unit) -> Unit,
) {
    private val rows = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 8, 24, 8) }
    private val dialog = AlertDialog.Builder(activity).setTitle("Review attachments")
        .setView(ScrollView(activity).apply { addView(rows) })
        .setNegativeButton("Keep draft", null).setPositiveButton("Send", null).create()
    fun show() {
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false
            dialog.setCancelable(false)
            onSend { dialog.dismiss() }
        }
        render()
    }
    private fun render() {
        rows.removeAllViews()
        val draft = client.composerDraft(channel.channelId)
        rows.addView(TextView(activity).apply { text = "Up to 10 items · 25 MiB each · 4096 UTF-8 bytes per caption. Nothing sends until you choose Send." })
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = draft.attachments.isNotEmpty()
        draft.attachments.forEachIndexed { index, item ->
            if (item.mimeType.startsWith("image/")) {
                val preview = ImageView(activity).apply { adjustViewBounds = true; maxHeight = (220 * resources.displayMetrics.density).toInt(); contentDescription = item.fileName }
                rows.addView(preview, LinearLayout.LayoutParams(-1, -2))
                thread(name = "ptt-staged-preview") {
                    val image = runCatching {
                        val bytes = client.stagedAttachmentData(item.id, channel.channelId)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = 4 })
                    }.getOrNull()
                    activity.runOnUiThread { if (preview.isAttachedToWindow) preview.setImageBitmap(image) else image?.recycle() }
                }
            }
            rows.addView(TextView(activity).apply { text = item.fileName; textSize = 18f; setPadding(0, 18, 0, 6) })
            val caption = EditText(activity).apply { hint = "Caption"; setText(item.caption); maxLines = 5 }
            caption.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    val text = s?.toString().orEmpty()
                    if (text.toByteArray().size > 4096) { caption.error = "Caption exceeds 4096 UTF-8 bytes"; dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = false; return }
                    runCatching { client.updateStagedCaption(channel.channelId, item.id, text) }
                        .onSuccess { caption.error = null }
                        .onFailure { caption.error = "Could not save caption" }
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).isEnabled = rows.touchables.filterIsInstance<EditText>().none { it.error != null }
                }
            })
            rows.addView(caption)
            val actions = LinearLayout(activity)
            fun move(offset: Int) {
                client.moveStagedAttachment(channel.channelId, item.id, offset); render()
            }
            actions.addView(Button(activity).apply { text = "Earlier"; isEnabled = index > 0; setOnClickListener { move(-1) } })
            actions.addView(Button(activity).apply { text = "Later"; isEnabled = index < draft.attachments.lastIndex; setOnClickListener { move(1) } })
            actions.addView(Button(activity).apply { text = "Remove"; setOnClickListener { client.discardStagedAttachment(item.id, channel.channelId); render() } })
            rows.addView(actions)
        }
    }
}
