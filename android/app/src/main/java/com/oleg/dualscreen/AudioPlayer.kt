package com.oleg.dualscreen

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Plays raw interleaved PCM16 48kHz stereo chunks from the Mac.
 * A queue + player thread decouples blocking AudioTrack writes from the
 * network reader (which must never stall — it also carries video frames).
 */
class AudioPlayer {
    private var track: AudioTrack? = null
    private val queue = LinkedBlockingQueue<ByteArray>(256)
    private val running = AtomicBoolean(false)
    @Volatile var overflowed = false

    fun start() {
        if (running.get()) return
        val minBuf = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val bufBytes = maxOf(minBuf, SAMPLE_RATE * 2 * 2 / 5) // >= 200 ms
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build())
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufBytes)
            .build()
        t.play()
        track = t
        running.set(true)
        overflowed = false
        queue.clear()

        Thread({
            while (running.get()) {
                val chunk = queue.poll() ?: continue
                try {
                    t.write(chunk, 0, chunk.size)
                } catch (_: Exception) {
                    break
                }
            }
        }, "dsxp-audio").start()
    }

    fun feed(pcm: ByteArray) {
        if (!running.get()) return
        if (!queue.offer(pcm)) {
            // consumer fell behind: drop the oldest chunk to keep latency low
            queue.poll()
            queue.offer(pcm)
            overflowed = true
        }
    }

    fun stop() {
        running.set(false)
        runCatching { track?.stop() }
        runCatching { track?.release() }
        track = null
        queue.clear()
    }

    companion object {
        const val SAMPLE_RATE = 48_000
    }
}
