package com.oleg.dualscreen

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.view.Surface

/**
 * Low-latency HEVC decoder: consumes Annex-B access units, renders straight
 * to the SurfaceView surface. The Mac host inlines VPS/SPS/PPS in every
 * keyframe; the first keyframe is harvested into csd-0 for codec config
 * (Snapdragon decoders refuse to configure without it).
 */
class VideoDecoder(private val surface: Surface, private val width: Int, private val height: Int) {

    private var codec: MediaCodec? = null
    @Volatile private var running = false
    @Volatile var started = false
        private set
    private var inputPts = 0L
    private var frameCount = 0L
    private var windowStart = System.currentTimeMillis()
    @Volatile var fps = 0.0
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
            c.configure(format, surface, null, 0)
            c.start()
            codec = c
            running = true
            started = true
            Thread({ drainOutput() }, "dsxp-drain").start()
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

    /** Feed one Annex-B access unit (the keyframe that started the codec too). */
    fun feed(accessUnit: ByteArray) {
        val c = codec ?: return
        if (!running) return
        try {
            val index = c.dequeueInputBuffer(50_000)
            if (index >= 0) {
                val buf = c.getInputBuffer(index) ?: return
                buf.clear()
                buf.put(accessUnit)
                inputPts += 1_000_000 / 240
                c.queueInputBuffer(index, 0, accessUnit.size, inputPts, 0)
            }
        } catch (_: Exception) {
            running = false
        }
    }

    private fun drainOutput() {
        val c = codec ?: return
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                val out = c.dequeueOutputBuffer(info, 10_000)
                if (out >= 0) {
                    c.releaseOutputBuffer(out, true)
                    frameCount++
                    val now = System.currentTimeMillis()
                    val dt = now - windowStart
                    if (dt >= 1000) {
                        fps = frameCount * 1000.0 / dt
                        frameCount = 0
                        windowStart = now
                    }
                } else {
                    Thread.sleep(1)
                }
            } catch (_: Exception) {
                break
            }
        }
    }

    fun stop() {
        running = false
        started = false
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        codec = null
    }
}
