package app.ptt.talk

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.SeekBar
import kotlin.math.max

/** A real encrypted voice-message waveform that also acts as the seek control. */
internal class ChatVoiceWaveformView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    var samples: ByteArray = byteArrayOf()
        set(value) { field = value.copyOf(); invalidate() }
    var progress: Float = 0f
        set(value) { field = value.coerceIn(0f, 1f); invalidate() }
    var tintColor: Int = 0xff0084a8.toInt()
        set(value) { field = value; invalidate() }
    var onSeek: ((Float) -> Unit)? = null

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val density = resources.displayMetrics.density

    init {
        isFocusable = true
        isClickable = true
        contentDescription = "Voice message waveform"
        minimumHeight = (32 * density).toInt()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            resolveSize((180 * density).toInt(), widthMeasureSpec),
            resolveSize((32 * density).toInt(), heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val values = if (samples.isEmpty()) ByteArray(24) { 72 } else samples
        val spacing = 2 * density
        val barWidth = max(density, (width - spacing * (values.size - 1)) / values.size)
        values.forEachIndexed { index, byte ->
            val normalized = max(0.12f, (byte.toInt() and 0xff) / 255f)
            val barHeight = max(3 * density, normalized * height)
            val left = index * (barWidth + spacing)
            paint.color = tintColor
            paint.alpha = if ((index + 1f) / values.size <= progress) 255 else 88
            canvas.drawRoundRect(
                RectF(left, (height - barHeight) / 2, left + barWidth, (height + barHeight) / 2),
                minOf(barWidth / 2, 2 * density), minOf(barWidth / 2, 2 * density), paint,
            )
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN || event.actionMasked == MotionEvent.ACTION_MOVE) {
            parent?.requestDisallowInterceptTouchEvent(true)
            seekTo(event.x / max(1, width).toFloat())
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            performClick()
            parent?.requestDisallowInterceptTouchEvent(false)
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
            parent?.requestDisallowInterceptTouchEvent(false)
            return true
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = SeekBar::class.java.name
        info.rangeInfo = AccessibilityNodeInfo.RangeInfo.obtain(
            AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 1f, progress,
        )
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when (action) {
        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> { seekTo(progress + 0.05f); true }
        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> { seekTo(progress - 0.05f); true }
        else -> super.performAccessibilityAction(action, arguments)
    }

    private fun seekTo(value: Float) {
        progress = value.coerceIn(0f, 1f)
        onSeek?.invoke(progress)
        sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_VIEW_SELECTED)
    }
}
