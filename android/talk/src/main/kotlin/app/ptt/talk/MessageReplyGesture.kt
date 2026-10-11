package app.ptt.talk

import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs

/** One reply action for touch, TalkBack, and the message menu. */
internal object MessageReplyGesture {
    private const val REPLY_ACTION = 0x010200ff

    fun install(view: View, reply: () -> Unit) {
        view.accessibilityDelegate = object : View.AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.addAction(AccessibilityNodeInfo.AccessibilityAction(REPLY_ACTION, "Reply"))
            }
            override fun performAccessibilityAction(host: View, action: Int, args: Bundle?): Boolean {
                if (action == REPLY_ACTION) { reply(); return true }
                return super.performAccessibilityAction(host, action, args)
            }
        }
        var startX = 0f
        var startY = 0f
        var horizontal = false
        val distance = 64 * view.resources.displayMetrics.density
        view.setOnTouchListener { target, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { startX = event.x; startY = event.y; horizontal = false }
                MotionEvent.ACTION_MOVE -> {
                    if (event.x - startX > distance / 2 && abs(event.y - startY) < distance / 3) {
                        horizontal = true
                        target.parent?.requestDisallowInterceptTouchEvent(true)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    target.parent?.requestDisallowInterceptTouchEvent(false)
                    if (horizontal && event.x - startX > distance && abs(event.y - startY) < distance / 2) {
                        target.cancelLongPress()
                        reply()
                        return@setOnTouchListener true
                    }
                    if (horizontal) { target.performClick(); return@setOnTouchListener true }
                }
                MotionEvent.ACTION_CANCEL -> { horizontal = false; target.parent?.requestDisallowInterceptTouchEvent(false) }
            }
            false
        }
    }
}
