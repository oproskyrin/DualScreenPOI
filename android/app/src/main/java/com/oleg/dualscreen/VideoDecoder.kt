package com.oleg.dualscreen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

/**
 * Low-latency HEVC decoder: consumes Annex-B access units, renders straight
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
    private val clockOffsetNs: () -> Long = { 0L }
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

    /** Splits an Annex-B access unit into NAL units (without start codes). */
    private fun splitNals(au: ByteArray): List<Pair<Int, ByteArray>> {
        val nals = ArrayList<Pair<Int, ByteArray>>()
        var i = 0
        val starts = ArrayList<Int>()
        while (i < au.size - 3) {
            if (au[i] == 0.toByte() && au[i + 1] == 0.toByte()) {
                if (au[i + 2] == 1.toByte()) { starts.add(i + 3); i += 3; continue }
                if (i < au.size - 4 && au[i + 2] == 0.toByte() && au[i + 3] == 1.toByte()) {
                    starts.add(i + 4); i += 4; continue
                }
            }
            i++
        }
        for (j in starts.indices) {
            val from = starts[j]
            val to = if (j + 1 < starts.size) starts[j + 1] - (if (au[starts[j + 1] - 1] == 0.toByte()) 4 else 3) else au.size
            if (to <= from) continue
            val nal = au.copyOfRange(from, to)
            // HEVC NAL type: first byte's bits 1..6
            val type = (nal[0].toInt() and 0x7E) shr 1
            nals.add(type to nal)
        }
        return nals
    }

    /** Starts the codec from a keyframe access unit. Returns true on success. */
    fun startFromKeyframe(keyAu: ByteArray): Boolean {
        val paramSets = splitNals(keyAu).filter { (t, _) -> t == 32 || t == 33 || t == 34 }
        if (paramSets.size < 3) return false

        var csdLen = 0
        for ((_, nal) in paramSets) csdLen += 4 + nal.size
        val csd = ByteArray(csdLen)
        var off = 0
        for ((_, nal) in paramSets) {
            csd[off++] = 0; csd[off++] = 0; csd[off++] = 0; csd[off++] = 1
            System.arraycopy(nal, 0, csd, off, nal.size)
            off += nal.size
        }

        return try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd))
            if (Build.VERSION.SDK_INT >= 30) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            runCatching { format.setInteger("vendor.low-latency.enable", 1) }
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
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

    /** True if this access unit carries parameter sets (keyframe). */
    fun isKeyframe(au: ByteArray): Boolean {
        val firstTypes = splitNals(au).map { it.first }
        return firstTypes.contains(32) && firstTypes.contains(33)
    }

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
