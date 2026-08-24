package app.ptt.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import java.io.Closeable
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

const val VOICE_SAMPLE_RATE = 48_000
const val VOICE_FRAME_MS = 20
const val VOICE_SAMPLES_PER_FRAME = VOICE_SAMPLE_RATE * VOICE_FRAME_MS / 1_000

data class CaptureLevel(val peak: Float, val rms: Float, val dbfs: Float)

/** Platform capture/playback with 20 ms frames; Opus and SFrame remain above this boundary. */
class AndroidAudioEngine(context: Context) : Closeable {
    private val app = context.applicationContext
    private val manager = app.getSystemService(AudioManager::class.java)
    private val lock = Any()
    private var recorder: AudioRecord? = null
    private var captureThread: Thread? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var player: AudioTrack? = null

    @SuppressLint("MissingPermission")
    fun startCapture(onFrame: (ShortArray, CaptureLevel) -> Unit) {
        check(app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "microphone permission is required"
        }
        synchronized(lock) {
            check(recorder == null) { "capture already started" }
            val minimum =
                AudioRecord.getMinBufferSize(
                    VOICE_SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
            check(minimum > 0) { "48 kHz mono capture is unavailable" }
            val created =
                AudioRecord.Builder()
                    .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(VOICE_SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build(),
                    )
                    .setBufferSizeInBytes(maxOf(minimum, VOICE_SAMPLES_PER_FRAME * 2 * 4))
                    .build()
            check(created.state == AudioRecord.STATE_INITIALIZED) { "microphone initialization failed" }
            echoCanceler =
                if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(created.audioSessionId)?.apply { enabled = true }
                else null
            noiseSuppressor =
                if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(created.audioSessionId)?.apply { enabled = true }
                else null
            requestAudioFocus()
            created.startRecording()
            recorder = created
            captureThread =
                thread(name = "ptt-audio-capture", priority = Thread.MAX_PRIORITY) {
                    val frame = ShortArray(VOICE_SAMPLES_PER_FRAME)
                    while (!Thread.currentThread().isInterrupted) {
                        var offset = 0
                        while (offset < frame.size) {
                            val count = created.read(frame, offset, frame.size - offset, AudioRecord.READ_BLOCKING)
                            if (count <= 0) return@thread
                            offset += count
                        }
                        onFrame(frame.copyOf(), measure(frame))
                    }
                }
        }
    }

    fun stopCapture() {
        val active: AudioRecord?
        val worker: Thread?
        synchronized(lock) {
            active = recorder
            worker = captureThread
            recorder = null
            captureThread = null
        }
        worker?.interrupt()
        runCatching { active?.stop() }
        worker?.join(500)
        echoCanceler?.release()
        echoCanceler = null
        noiseSuppressor?.release()
        noiseSuppressor = null
        active?.release()
    }

    fun play(frame: ShortArray) {
        require(frame.size == VOICE_SAMPLES_PER_FRAME) { "playback requires one 20 ms frame" }
        val track = synchronized(lock) { player ?: createPlayer().also { player = it } }
        track.write(frame, 0, frame.size, AudioTrack.WRITE_BLOCKING)
    }

    override fun close() {
        stopCapture()
        synchronized(lock) {
            player?.run {
                runCatching { stop() }
                release()
            }
            player = null
        }
        @Suppress("DEPRECATION")
        manager.abandonAudioFocus(null)
        manager.mode = AudioManager.MODE_NORMAL
    }

    private fun createPlayer(): AudioTrack {
        val minimum =
            AudioTrack.getMinBufferSize(
                VOICE_SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
        check(minimum > 0) { "48 kHz mono playback is unavailable" }
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(VOICE_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minimum, VOICE_SAMPLES_PER_FRAME * 2 * 6))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .also {
                check(it.state == AudioTrack.STATE_INITIALIZED) { "speaker initialization failed" }
                it.play()
            }
    }

    @Suppress("DEPRECATION")
    private fun requestAudioFocus() {
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        manager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
    }

    private fun measure(frame: ShortArray): CaptureLevel {
        var peak = 0
        var squares = 0.0
        for (sample in frame) {
            val value = sample.toInt()
            peak = maxOf(peak, kotlin.math.abs(value))
            val normalized = value / 32767.0
            squares += normalized * normalized
        }
        val rms = sqrt(squares / frame.size).toFloat()
        return CaptureLevel(
            peak = (peak / 32767f).coerceAtMost(1f),
            rms = rms,
            dbfs = if (rms <= Float.MIN_VALUE) -96f else (20f * log10(rms)).coerceAtLeast(-96f),
        )
    }
}
