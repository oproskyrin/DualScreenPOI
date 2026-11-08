package com.oleg.dualscreen

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/**
 * Real capture device for [MicStreamer]: AudioRecord at 48 kHz mono PCM16.
 * VOICE_COMMUNICATION first (device echo/acoustic processing), plain MIC as
 * fallback when the source refuses to initialize. Permission is checked by
 * MainActivity — and again by MicStreamer.permissionGranted — before this
 * class is ever started.
 */
@SuppressLint("MissingPermission") // RECORD_AUDIO is gated by the toggle + runtime request
class AudioRecordMicRecorder : MicStreamer.MicRecorder {
    private var record: AudioRecord? = null

    override fun start(): Boolean {
        val minBuf = AudioRecord.getMinBufferSize(
            MicStreamer.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) return false
        val bufferBytes = maxOf(minBuf, MicStreamer.frameBytes() * 4)
        for (source in intArrayOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.MIC)) {
            val rec = try {
                @Suppress("DEPRECATION") // constructor form kept: device runs API 33
                AudioRecord(source, MicStreamer.SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferBytes)
            } catch (e: Exception) { continue }
            try {
                if (rec.state == AudioRecord.STATE_INITIALIZED) {
                    rec.startRecording()
                    if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        record = rec
                        return true
                    }
                }
                runCatching { rec.release() }
            } catch (e: Exception) {
                runCatching { rec.release() }
            }
        }
        return false
    }

    override fun read(buffer: ByteArray): Int = try {
        record?.read(buffer, 0, buffer.size) ?: -1
    } catch (e: Exception) {
        -1
    }

    override fun stop() {
        record?.let { rec ->
            runCatching { if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) rec.stop() }
            runCatching { rec.release() }
        }
        record = null
    }
}
