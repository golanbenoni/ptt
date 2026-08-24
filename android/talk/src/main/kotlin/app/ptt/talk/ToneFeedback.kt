package app.ptt.talk

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper

/** Reusable feedback player. Explicit stop/restart avoids the old first-tone-only failure. */
internal class ToneFeedback {
    private val handler = Handler(Looper.getMainLooper())
    private var generator: ToneGenerator? = null

    fun granted() = play(ToneGenerator.TONE_PROP_ACK, 110)

    fun released() = play(ToneGenerator.TONE_PROP_BEEP2, 90)

    fun denied() = play(ToneGenerator.TONE_PROP_NACK, 180)

    fun close() {
        handler.removeCallbacksAndMessages(null)
        generator?.release()
        generator = null
    }

    private fun play(tone: Int, durationMs: Int) {
        handler.post {
            val active = generator ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, 72).also { generator = it }
            active.stopTone()
            active.startTone(tone, durationMs)
        }
    }
}
