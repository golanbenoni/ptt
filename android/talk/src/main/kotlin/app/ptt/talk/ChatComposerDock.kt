package app.ptt.talk

import android.content.Context
import android.widget.LinearLayout

/** Keeps composing and recording controls outside the history scroll viewport. */
internal class ChatComposerDock(context: Context, content: LinearLayout, firstComposerIndex: Int) : LinearLayout(context) {
    init {
        orientation = VERTICAL
        val inset = (12 * resources.displayMetrics.density).toInt()
        setPadding(inset, inset / 2, inset, inset / 2)
        while (content.childCount > firstComposerIndex) {
            val child = content.getChildAt(firstComposerIndex)
            content.removeViewAt(firstComposerIndex)
            addView(child)
        }
    }
}
