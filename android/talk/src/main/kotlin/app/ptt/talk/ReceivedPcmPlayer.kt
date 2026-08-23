package app.ptt.talk

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock
import app.ptt.media.SAMPLE_RATE
import kotlin.math.max

internal object ReceivedPcmPlayer {
    fun playBlocking(context: Context, pcm: ByteArray) {
        require(pcm.isNotEmpty()) { "received no PCM samples" }
        require(pcm.size % Short.SIZE_BYTES == 0) { "received an incomplete PCM sample" }

        val audioManager = context.getSystemService(AudioManager::class.java)
        val previousMode = audioManager.mode
        @Suppress("DEPRECATION")
        val previousSpeakerphone = audioManager.isSpeakerphoneOn

        val minimumBufferSize =
            AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
        check(minimumBufferSize > 0) { "audio output does not support 16 kHz mono PCM" }

        val track =
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(max(minimumBufferSize, pcm.size))
                .build()

        check(track.state == AudioTrack.STATE_INITIALIZED) { "could not initialize audio output" }
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            routeToSpeaker(audioManager)

            track.play()
            val written = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
            check(written == pcm.size) { "audio output accepted $written of ${pcm.size} bytes" }

            val sampleCount = pcm.size / Short.SIZE_BYTES
            val deadline = SystemClock.elapsedRealtime() + (sampleCount * 1_000L / SAMPLE_RATE) + 1_000L
            while (track.playbackHeadPosition < sampleCount && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(10)
            }
            check(track.playbackHeadPosition >= sampleCount) { "audio output timed out" }
        } finally {
            if (track.playState != AudioTrack.PLAYSTATE_STOPPED) {
                track.stop()
            }
            track.release()
            restoreRoute(audioManager, previousMode, previousSpeakerphone)
        }
    }

    private fun routeToSpeaker(audioManager: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker =
                audioManager.availableCommunicationDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                }
            if (speaker != null) {
                check(audioManager.setCommunicationDevice(speaker)) { "could not route audio to speaker" }
                return
            }
        }
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = true
    }

    private fun restoreRoute(audioManager: AudioManager, mode: Int, speakerphone: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        }
        @Suppress("DEPRECATION")
        run {
            audioManager.isSpeakerphoneOn = speakerphone
        }
        audioManager.mode = mode
    }
}
