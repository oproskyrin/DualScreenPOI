package com.oleg.dualscreen

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.LinkedBlockingQueue


/**
 * Plays raw interleaved PCM16 48kHz stereo chunks from the Mac.
 * A queue + player thread decouples blocking AudioTrack writes from the
 * network reader (which must never stall — it also carries video frames).
 */
class AudioPlayer {
    private class Playback(val track: AudioTrack) {
        val queue = LinkedBlockingQueue<ByteArray>(16)
        @Volatile var running = true
        var thread: Thread? = null
    }
    @Volatile private var playback: Playback? = null
    @Volatile var overflowed = false

    @Synchronized fun start() {
        if (playback != null) return
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
        try { t.play() } catch (e: Exception) { t.release(); throw e }
        val current = Playback(t)
        playback = current
        overflowed = false

        current.thread = Thread({
            try {
                while (current.running) {
                    // Block when silent; never busy-spin and never reuse an old
                    // worker's queue when a new session starts.
                    val chunk = current.queue.take()
                    var offset = 0
                    while (current.running && offset < chunk.size) {
                        val written = t.write(chunk, offset, chunk.size - offset, AudioTrack.WRITE_BLOCKING)
                        if (written <= 0) return@Thread
                        offset += written
                    }
                }
            } catch (_: InterruptedException) {
                // Deliberate stop.
            } catch (_: Exception) {
                // Audio failures must not tear down the video reader.
            } finally {
                current.running = false
                runCatching { t.stop() }
                runCatching { t.release() }
                synchronized(this@AudioPlayer) { if (playback === current) playback = null }
            }
        }, "dsxp-audio").also { it.start() }
    }

    fun feed(pcm: ByteArray) {
        val current = playback ?: return
        if (!current.running) return
        if (!current.queue.offer(pcm)) {
            // consumer fell behind: drop the oldest chunk to keep latency low
            current.queue.poll()
            current.queue.offer(pcm)
            overflowed = true
        }
    }

    @Synchronized fun stop() {
        val current = playback ?: return
        playback = null
        current.running = false
        current.queue.clear()
        current.thread?.interrupt()
        // stop unblocks native blocking writes. The owning worker alone releases
        // the track, avoiding release/write races across reconnects.
        runCatching { current.track.pause() }
        runCatching { current.track.flush() }
        runCatching { current.track.stop() }
    }

    companion object {
        const val SAMPLE_RATE = 48_000
    }
}
