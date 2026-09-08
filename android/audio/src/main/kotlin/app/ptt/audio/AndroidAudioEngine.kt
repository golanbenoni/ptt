package app.ptt.audio

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
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
                        // The physical release gate records this short, local-only marker with an
                        // independent microphone. Synthetic network audio starts immediately after
                        // the hardware playback head reaches the marker, so the analyzer can measure
                        // actual source-to-receiver-speaker latency instead of trusting app callbacks.
                        playSyntheticSourceMarker()
                        var sampleOffset = 0L
                        var nextFrameAt = System.nanoTime()
                        while (!Thread.currentThread().isInterrupted) {
                            val frame =
                                ShortArray(VOICE_SAMPLES_PER_FRAME) { sampleIndex ->
                                    val phase =
                                        (sampleOffset + sampleIndex).toDouble() *
                                            2.0 * Math.PI * 997.0 / VOICE_SAMPLE_RATE
                                    // Leave enough acoustic headroom for the quieter speaker in a
                                    // two-device room-microphone gate. This path exists only in the
                                    // debug physical fixture; production microphone levels are
                                    // neither generated nor amplified here.
                                    (kotlin.math.sin(phase) * 28_000).toInt().toShort()
                                }
                            sampleOffset += VOICE_SAMPLES_PER_FRAME
                            onFrame(frame, measure(frame))
                            nextFrameAt += VOICE_FRAME_MS * 1_000_000L
                            val remainingNs = nextFrameAt - System.nanoTime()
                            try {
                                if (remainingNs > 0) {
                                    Thread.sleep(remainingNs / 1_000_000L, (remainingNs % 1_000_000L).toInt())
                                } else if (remainingNs < -(VOICE_FRAME_MS * 5L * 1_000_000L)) {
                                    // Do not emit an unbounded catch-up burst after a debugger or
                                    // scheduler stall; resume from the current hardware clock.
                                    nextFrameAt = System.nanoTime()
                                }
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
            val track = ensurePlayerLocked()
            val written = track.write(frame, 0, frame.size, AudioTrack.WRITE_BLOCKING)
            check(written == frame.size) { "audio output accepted $written of ${frame.size} frames" }
            // Prime a stopped streaming track before asking hardware to run it. Starting an
            // empty track can immediately underrun and leave the playback head parked on
            // some Samsung audio services even though later writes report success.
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
            playbackFramesWritten += written
            playbackFramesWritten
        }
    }

    /** Opens the authenticated incoming route while control delivery is ahead of media packets. */
    fun preparePlayback() {
        synchronized(lock) { ensurePlayerLocked() }
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

    /** Privacy-safe output diagnostics used by the on-device release preflight. */
    internal fun playbackDiagnostics(): String = synchronized(lock) {
        val active = player ?: return@synchronized "playback=uninitialized"
        val routeType = active.routedDevice?.type ?: AudioDeviceInfo.TYPE_UNKNOWN
        "buffer=${active.bufferSizeInFrames}frames " +
            "capacity=${active.bufferCapacityInFrames}frames " +
            "threshold=${if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) active.startThresholdInFrames else -1}frames " +
            "performance=${active.performanceMode} route=$routeType mode=${manager.mode}"
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
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            manager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            run {
                manager.isSpeakerphoneOn = false
                manager.stopBluetoothSco()
            }
        }
        manager.mode = AudioManager.MODE_NORMAL
    }

    private fun currentPlaybackFrameLocked(): Long {
        val raw = player?.playbackHeadPosition?.toLong()?.and(0xffff_ffffL) ?: return 0
        if (raw < lastPlaybackHead && lastPlaybackHead - raw > 0x8000_0000L) playbackHeadWraps += 1
        lastPlaybackHead = raw
        return (playbackHeadWraps shl 32) or raw
    }

    private fun ensurePlayerLocked(): AudioTrack =
        player ?: run {
            // A receive-only session never starts capture, so it has not yet entered
            // communication mode or selected an audible output. Configure the route
            // before creating the first AudioTrack; otherwise Android commonly leaves
            // VOICE_COMMUNICATION on the earpiece while writes and playback-head checks
            // still report success.
            requestAudioFocus()
            createPlayer().also {
                player = it
                playbackFramesWritten = 0
                playbackHeadWraps = 0
                lastPlaybackHead = 0
            }
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
            // Keep only enough PCM queued to absorb ordinary scheduler jitter. Six frames
            // added up to 120 ms before OEM output latency and the network jitter buffer;
            // three frames retain headroom without making short PTT speech feel delayed.
            .setBufferSizeInBytes(maxOf(minimum, VOICE_SAMPLES_PER_FRAME * 2 * 3))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
            .also {
                check(it.state == AudioTrack.STATE_INITIALIZED) { "speaker initialization failed" }
                val resized = it.setBufferSizeInFrames(VOICE_SAMPLES_PER_FRAME * 2)
                check(resized > 0) { "low-latency speaker buffer is unavailable" }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                    // One complete 20 ms frame is sufficient to start voice promptly. The
                    // platform default can equal the full OEM buffer and delay or prevent
                    // short PTT bursts from starting after an underrun.
                    it.setStartThresholdInFrames(VOICE_SAMPLES_PER_FRAME)
                }
            }
    }

    private fun playSyntheticSourceMarker() {
        val marker =
            ShortArray(VOICE_SAMPLES_PER_FRAME * SYNTHETIC_SOURCE_MARKER_FRAMES) { sampleIndex ->
                val phase =
                    sampleIndex.toDouble() *
                        2.0 * Math.PI * SYNTHETIC_SOURCE_MARKER_HZ / VOICE_SAMPLE_RATE
                (kotlin.math.sin(phase) * 20_000).toInt().toShort()
            }
        repeat(2) {
            val completed = runCatching {
                val markerTrack = createMarkerPlayer(marker.size)
                var handedToCleanup = false
                try {
                    val written = markerTrack.write(marker, 0, marker.size, AudioTrack.WRITE_BLOCKING)
                    check(written == marker.size) { "source marker accepted $written of ${marker.size} frames" }
                    markerTrack.play()
                    // Confirm that hardware has started, then let encrypted synthetic speech
                    // begin while the marker finishes on its independent track. Waiting for the
                    // entire marker here can consume a short PTT hold on a busy OEM audio service,
                    // leaving the receiver with only the encrypted END frame and no audible voice.
                    val deadline = System.nanoTime() + 300_000_000L
                    while (System.nanoTime() < deadline) {
                        if (markerTrack.playbackHeadPosition.toLong().and(0xffff_ffffL) > 0) {
                            handedToCleanup = true
                            releaseMarkerAfterPlayback(markerTrack, marker.size)
                            return@runCatching true
                        }
                        Thread.sleep(10)
                    }
                    false
                } finally {
                    if (!handedToCleanup) {
                        runCatching { markerTrack.stop() }
                        markerTrack.release()
                    }
                }
            }.getOrDefault(false)
            if (completed) return
            // Samsung audio services can transiently refuse a new output immediately after
            // the hardware gate releases its track. Give the service one scheduling turn before
            // recreating this test-only marker; failure must never crash the voice process.
            Thread.sleep(50)
        }
        error("synthetic source marker did not reach the speaker")
    }

    private fun releaseMarkerAfterPlayback(markerTrack: AudioTrack, targetFrame: Int) {
        thread(name = "ptt-acoustic-marker-cleanup") {
            try {
                val deadline = System.nanoTime() + 2_000_000_000L
                while (System.nanoTime() < deadline &&
                    markerTrack.playbackHeadPosition.toLong().and(0xffff_ffffL) < targetFrame
                ) {
                    Thread.sleep(10)
                }
            } finally {
                runCatching { markerTrack.stop() }
                markerTrack.release()
            }
        }
    }

    private fun createMarkerPlayer(sampleCount: Int): AudioTrack {
        val minimum =
            AudioTrack.getMinBufferSize(
                VOICE_SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
        check(minimum > 0) { "source marker playback is unavailable" }
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
            // MODE_STATIC is not consistently supported for VOICE_COMMUNICATION on Samsung.
            // A dedicated, prefilled streaming track keeps the marker isolated from production
            // playback while using the OEM's proven voice-output path.
            .setBufferSizeInBytes(maxOf(minimum, sampleCount * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .also { check(it.state == AudioTrack.STATE_INITIALIZED) { "source marker speaker initialization failed" } }
    }

    @Suppress("DEPRECATION")
    private fun requestAudioFocus() {
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        selectCommunicationOutput()
        manager.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
    }

    /**
     * PTT audio must be audible without asking the user to hold the phone like a call.
     * Prefer an attached private route, otherwise explicitly use the loudspeaker instead
     * of Android's MODE_IN_COMMUNICATION earpiece default.
     */
    @Suppress("DEPRECATION")
    private fun selectCommunicationOutput() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            val devices = manager.availableCommunicationDevices
            val preferred =
                devices.firstOrNull { it.type in PRIVATE_COMMUNICATION_DEVICE_TYPES }
                    ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    ?: return
            check(manager.setCommunicationDevice(preferred)) {
                "audio output route ${preferred.type} is unavailable"
            }
            return
        }

        val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val hasBluetooth = outputs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        val hasWired = outputs.any { it.type in WIRED_COMMUNICATION_DEVICE_TYPES }
        when {
            hasBluetooth -> {
                manager.isSpeakerphoneOn = false
                manager.startBluetoothSco()
                manager.isBluetoothScoOn = true
            }
            hasWired -> manager.isSpeakerphoneOn = false
            else -> manager.isSpeakerphoneOn = true
        }
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

    private companion object {
        const val SYNTHETIC_SOURCE_MARKER_HZ = 613.0
        const val SYNTHETIC_SOURCE_MARKER_FRAMES = 10

        val WIRED_COMMUNICATION_DEVICE_TYPES =
            setOf(
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET,
            )

        val PRIVATE_COMMUNICATION_DEVICE_TYPES =
            WIRED_COMMUNICATION_DEVICE_TYPES +
                setOf(
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER,
                )
    }
}
