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
class AndroidAudioEngine(
    context: Context,
    private val syntheticCapture: Boolean = false,
) : Closeable {
    private val app = context.applicationContext
    private val manager = app.getSystemService(AudioManager::class.java)
    private val lock = Any()
    private var recorder: AudioRecord? = null
    private var captureThread: Thread? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var player: AudioTrack? = null
    private var playbackFramesWritten = 0L
    private var playbackHeadWraps = 0L
    private var lastPlaybackHead = 0L

    @SuppressLint("MissingPermission")
    fun startCapture(onFrame: (ShortArray, CaptureLevel) -> Unit) {
        check(app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "microphone permission is required"
        }
        synchronized(lock) {
            check(recorder == null && captureThread == null) { "capture already started" }
            if (syntheticCapture) {
                requestAudioFocus()
                captureThread =
                    thread(name = "ptt-audio-synthetic-capture", priority = Thread.MAX_PRIORITY) {
                        var sampleOffset = 0L
                        while (!Thread.currentThread().isInterrupted) {
                            val frame =
                                ShortArray(VOICE_SAMPLES_PER_FRAME) { sampleIndex ->
                                    val phase =
                                        (sampleOffset + sampleIndex).toDouble() *
                                            2.0 * Math.PI * 997.0 / VOICE_SAMPLE_RATE
                                    (kotlin.math.sin(phase) * 20_000).toInt().toShort()
                                }
                            sampleOffset += VOICE_SAMPLES_PER_FRAME
                            onFrame(frame, measure(frame))
                            try {
                                Thread.sleep(VOICE_FRAME_MS.toLong())
                            } catch (_: InterruptedException) {
                                break
                            }
                        }
                    }
                return
            }
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

    /** Returns the cumulative frame position that the hardware must reach for this write. */
    fun play(frame: ShortArray): Long {
        require(frame.size == VOICE_SAMPLES_PER_FRAME) { "playback requires one 20 ms frame" }
        return synchronized(lock) {
            val track = player ?: createPlayer().also {
                player = it
                playbackFramesWritten = 0
                playbackHeadWraps = 0
                lastPlaybackHead = 0
            }
            val written = track.write(frame, 0, frame.size, AudioTrack.WRITE_BLOCKING)
            check(written == frame.size) { "audio output accepted $written of ${frame.size} frames" }
            playbackFramesWritten += written
            playbackFramesWritten
        }
    }

    /**
     * Waits for AudioTrack's hardware playback head, rather than treating a successful buffer
     * write as audible output. The 32-bit hardware counter is extended so long-running foreground
     * sessions remain valid across a wrap.
     */
    fun awaitPlayback(targetFrame: Long, timeoutMs: Long = 3_000): Boolean {
        require(targetFrame > 0 && timeoutMs > 0)
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (System.nanoTime() < deadline) {
            val played = synchronized(lock) { currentPlaybackFrameLocked() }
            if (played >= targetFrame) return true
            try {
                Thread.sleep(10)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return false
    }

    override fun close() {
        stopCapture()
        synchronized(lock) {
            player?.run {
                runCatching { stop() }
                release()
            }
            player = null
            playbackFramesWritten = 0
            playbackHeadWraps = 0
            lastPlaybackHead = 0
        }
        @Suppress("DEPRECATION")
        manager.abandonAudioFocus(null)
        manager.mode = AudioManager.MODE_NORMAL
    }

    private fun currentPlaybackFrameLocked(): Long {
        val raw = player?.playbackHeadPosition?.toLong()?.and(0xffff_ffffL) ?: return 0
        if (raw < lastPlaybackHead && lastPlaybackHead - raw > 0x8000_0000L) playbackHeadWraps += 1
        lastPlaybackHead = raw
        return (playbackHeadWraps shl 32) or raw
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
