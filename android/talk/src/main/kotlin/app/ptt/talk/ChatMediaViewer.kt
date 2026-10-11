package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.BitmapFactory
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.ScrollView
import android.widget.TextView
import android.widget.VideoView
import java.io.File

internal object ChatMediaViewer {
    fun show(activity: Activity, file: File, mime: String, caption: String, save: () -> Unit) {
        val layout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setPadding(16, 16, 16, 16) }
        var video: VideoView? = null
        if (mime.startsWith("video/")) {
            video = VideoView(activity).apply {
                setVideoPath(file.absolutePath)
                setMediaController(MediaController(activity).also { it.setAnchorView(this) })
                setOnPreparedListener { seekTo(1) }
            }
            layout.addView(video, LinearLayout.LayoutParams(-1, (280 * activity.resources.displayMetrics.density).toInt()))
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
            val bitmap = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
            layout.addView(ImageView(activity).apply { setImageBitmap(bitmap); adjustViewBounds = true; maxHeight = (400 * resources.displayMetrics.density).toInt(); contentDescription = caption.ifBlank { "Photo" } })
        }
        layout.addView(TextView(activity).apply { text = caption; textSize = 16f; setPadding(0, 16, 0, 16) })
        AlertDialog.Builder(activity).setTitle("Media").setView(ScrollView(activity).apply { addView(layout) })
            .setNegativeButton("Done", null)
            .setNeutralButton("Save") { _, _ -> save() }
            .setPositiveButton("Share") { _, _ ->
                activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = mime; putExtra(Intent.EXTRA_STREAM, ChatAttachmentProvider.uri(activity, file))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, "Share attachment"))
            }.setOnDismissListener { video?.stopPlayback() }.show()
        // Grant-scoped share/save consumers need this file after the dialog closes.
        // ChatAttachmentProvider expires decrypted previews after fifteen minutes.
    }
}
