package com.oleg.dualscreen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

/**
 * Low-latency AVC/HEVC decoder: consumes Annex-B access units, renders straight
 * to the SurfaceView surface. The Mac host inlines VPS/SPS/PPS in every
 * keyframe; the first keyframe is harvested into csd-0 for codec config
 * (Snapdragon decoders refuse to configure without it).
 *
 * Fully asynchronous: MediaCodec.Callback on a dedicated handler thread.
 * [feed] never blocks the caller — if no input buffer is instantly free the
 * access unit goes into a small [AccessUnitQueue] that drops the oldest
 * non-keyframe on overflow, so the network reader thread never stalls.
 */
class VideoDecoder(
    private val surface: Surface,
    private val width: Int,
    private val height: Int,
    /** Optional capture-to-render measurement pipeline (see [RenderTiming]). */
    private val renderTiming: RenderTiming? = null,
    /** Host-vs-client clock offset in ns, re-read at every render. */
    private val clockOffsetNs: () -> Long = { 0L },
    val videoCodec: VideoCodec = VideoCodec.HEVC,
    private val decoderSupport: DecoderSupport = DecoderSupport.system()
) {

    companion object {
        /** Matches the host's reduced socket queue depth; small on purpose. */
        private const val PENDING_CAPACITY = 3
    }

    private var codec: MediaCodec? = null
    private var callbackThread: HandlerThread? = null
    @Volatile private var running = false
    @Volatile var started = false
        private set
    /** Guards freeInputs + pending + PTS assignment (network vs codec threads). */
    private val lock = Any()
    private val freeInputs = ArrayDeque<Int>()
    private val pending = AccessUnitQueue(PENDING_CAPACITY)
    private var inputPts = 0L
    // Output accounting: written only from the codec callback thread.
    private var frameCount = 0L
    private var windowStart = System.currentTimeMillis()
    @Volatile var fps = 0.0
    /** Smoothed decoder feed -> output latency, not capture-to-render, milliseconds. */
    @Volatile var latencyMs = 0.0
    var lastError: String? = null
        private set

    /** Starts the codec from a keyframe access unit. Returns true on success. */
    fun startFromKeyframe(keyAu: ByteArray): Boolean {
        val csd = AnnexB.configuration(keyAu, videoCodec) ?: return false

        return try {
            val format = MediaFormat.createVideoFormat(videoCodec.mime, width, height)
            csd.forEachIndexed { index, data -> format.setByteBuffer("csd-$index", java.nio.ByteBuffer.wrap(data)) }
            if (Build.VERSION.SDK_INT >= 30) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            runCatching { format.setInteger("vendor.low-latency.enable", 1) }
            val name = decoderSupport.decoderName(videoCodec, width, height)
                ?: error("${videoCodec.label} decoder unavailable for $width × $height")
            val c = MediaCodec.createByCodecName(name)
            codec = c // own the codec before configure/start, including failure paths
            val thread = HandlerThread("dsxp-codec").apply { start() }
            callbackThread = thread
            c.setCallback(callback, Handler(thread.looper))
            c.configure(format, surface, null, 0)
            c.start()
            running = true
            started = true
            true
        } catch (e: Exception) {
            lastError = e.message
            stop()
            false
        }
    }

    /** Recognizes IDR/IRAP even when parameter sets are not repeated. */
    fun isKeyframe(au: ByteArray): Boolean = AnnexB.isKeyframe(au, videoCodec)

    /**
     * Feed one Annex-B access unit (the keyframe that started the codec too).
     * Non-blocking: uses a free input buffer if one is available, otherwise
     * queues the AU with drop-oldest-delta policy on overflow.
     * [timing] is the 0x05 metadata that preceded this frame; it travels with
     * the AU so a dropped AU drops its timing entry with it.
     */
    fun feed(accessUnit: ByteArray, timing: FrameTiming? = null) {
        if (!running) return
        val c = codec ?: return
        synchronized(lock) {
            if (!running) return
            val index = freeInputs.removeFirstOrNull()
            if (index != null) {
                queueInput(c, index, accessUnit, timing)
            } else {
                pending.offer(accessUnit, isKeyframe(accessUnit), timing)
            }
        }
    }

    /** Queues one AU into an input buffer. Callers hold [lock] and check running. */
    private fun queueInput(c: MediaCodec, index: Int, au: ByteArray, timing: FrameTiming?) {
        try {
            val buf = c.getInputBuffer(index)
            if (buf == null) {
                freeInputs.addLast(index)
                return
            }
            buf.clear()
            buf.put(au)
            // Monotonic local PTS measures decoder feed -> output only.
            inputPts = System.nanoTime() / 1000
            c.queueInputBuffer(index, 0, au.size, inputPts, 0)
            if (timing != null) {
                renderTiming?.push(timing.capNs, timing.encNs, android.os.SystemClock.uptimeMillis() * 1_000_000L)
            }
        } catch (_: Exception) {
            running = false
        }
    }

    /** Moves as many queued AUs as possible into now-free input buffers. */
    private fun pumpPending(c: MediaCodec) {
        synchronized(lock) {
            while (running) {
                val index = freeInputs.removeFirstOrNull() ?: break
                val frame = pending.poll()
                if (frame == null) {
                    freeInputs.addLast(index)
                    break
                }
                queueInput(c, index, frame.data, frame.tag as FrameTiming?)
            }
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
            synchronized(lock) { freeInputs.addLast(index) }
            pumpPending(c)
        }

        override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                val nowUs = System.nanoTime() / 1000
                val lat = (nowUs - info.presentationTimeUs) / 1000.0
                if (lat in 0.0..500.0) { // sanity clamp
                    latencyMs = latencyMs * 0.8 + lat * 0.2
                }
                c.releaseOutputBuffer(index, true)
                renderTiming?.onRendered(
                    android.os.SystemClock.uptimeMillis() * 1_000_000L, clockOffsetNs())
                frameCount++
                val now = System.currentTimeMillis()
                val dt = now - windowStart
                if (dt >= 1000) {
                    fps = frameCount * 1000.0 / dt
                    frameCount = 0
                    windowStart = now
                }
            } catch (_: Exception) {
                // Codec already stopped/released between callback and use.
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            running = false
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
    }

    /** Safe from any thread (network, main, or callback thread). */
    fun stop() {
        running = false
        started = false
        synchronized(lock) { pending.clear(); freeInputs.clear() }
        val c = codec
        codec = null
        runCatching { c?.stop() }
        runCatching { c?.release() }
        callbackThread?.quitSafely()
        callbackThread = null
    }
}
