package com.oleg.dualscreen

import org.json.JSONObject

/**
 * Puts [value] into [json] only when it is finite (NaN/Infinite values are
 * illegal in org.json doubles and meaningless as reported metrics).
 */
fun putFinite(json: JSONObject, key: String, value: Double) {
    if (value.isFinite()) json.put(key, value)
}

/** Timing carried by a 0x05 frame, in host uptime nanoseconds. */
class FrameTiming(val seq: Long, val capNs: Long, val encNs: Long)

/**
 * Stash for the 0x05 video-timing JSON that arrives immediately before its
 * 0x01 video frame. A 0x05 without a following 0x01 (host skip) is simply
 * overwritten by the next one, so seq gaps never desync the pipeline.
 */
class VideoTimingStash {
    private var pending: FrameTiming? = null

    @Synchronized fun stash(timing: FrameTiming) { pending = timing }
    @Synchronized fun take(): FrameTiming? { val t = pending; pending = null; return t }
    @Synchronized fun clear() { pending = null }
}

/**
 * FIFO associating decoder submissions with rendered output buffers. The
 * decoder has no B-frames and produces output in order, so popping the head
 * at render time is the correct association. Bounded (drop-oldest) to survive
 * decoder stalls; results outside the sanity window update "last" but never
 * enter the rolling average.
 */
class RenderTiming(private val capacity: Int = 256, private val history: Int = 32) {
    private class Entry(val capNs: Long, val encNs: Long, val submitNs: Long)

    private val fifo = ArrayDeque<Entry>()
    private val capHistory = ArrayDeque<Double>()
    private val encHistory = ArrayDeque<Double>()
    private var lastCapMs = Double.NaN
    private var lastEncMs = Double.NaN
    private var avgCapMs = Double.NaN
    private var avgEncMs = Double.NaN
    var matchedFrames = 0L
        private set

    init { require(capacity >= 1) { "capacity must be >= 1" }; require(history >= 1) { "history must be >= 1" } }

    /** Called when an access unit is submitted to the decoder. */
    @Synchronized fun push(capNs: Long, encNs: Long, submitNs: Long) {
        if (fifo.size >= capacity) fifo.removeFirst()
        fifo.addLast(Entry(capNs, encNs, submitNs))
    }

    /** Called when an output buffer has been rendered on the surface. */
    @Synchronized fun onRendered(nowNs: Long, clockOffsetNs: Long) {
        val e = fifo.removeFirstOrNull() ?: return
        matchedFrames++
        // Render time is android-domain; θ converts android→host: host = android + θ.
        val cap = (nowNs + clockOffsetNs - e.capNs) / 1e6
        val enc = (nowNs + clockOffsetNs - e.encNs) / 1e6
        lastCapMs = cap
        lastEncMs = enc
        if (cap in 0.0..SANITY_MAX_MS && enc in 0.0..SANITY_MAX_MS) {
            capHistory.addLast(cap); if (capHistory.size > history) capHistory.removeFirst()
            encHistory.addLast(enc); if (encHistory.size > history) encHistory.removeFirst()
            avgCapMs = capHistory.average()
            avgEncMs = encHistory.average()
        }
    }

    @Synchronized fun pendingCount(): Int = fifo.size
    @Synchronized fun clear() {
        fifo.clear(); capHistory.clear(); encHistory.clear()
        lastCapMs = Double.NaN; lastEncMs = Double.NaN; avgCapMs = Double.NaN; avgEncMs = Double.NaN
        matchedFrames = 0
    }

    @Synchronized fun lastCapToRenderMs(): Double = lastCapMs
    @Synchronized fun lastEncToRenderMs(): Double = lastEncMs
    @Synchronized fun avgCapToRenderMs(): Double = avgCapMs
    @Synchronized fun avgEncToRenderMs(): Double = avgEncMs

    companion object { const val SANITY_MAX_MS = 10_000.0 }
}

/**
 * NTP-lite clock sync between host (Mac) and client (Android) uptime clocks.
 * Every stats send stamps "t1"; the host echoes {t1, t2, t3} and the client
 * adds t4 at arrival: θ = ((t2−t1)+(t3−t4))/2, rtt = (t4−t1)−(t3−t2).
 * The rolling window keeps the newest samples; the sample with the lowest
 * rtt provides the current offset. Samples older than [maxAgeMs] are purged.
 */
class ClockSync(
    private val window: Int = 16,
    private val t1Window: Int = 8,
    private val maxAgeMs: Long = 60_000
) {
    private class Sample(val thetaNs: Long, val rttNs: Long, val atMs: Long)

    private val sentT1 = ArrayDeque<Long>()
    private val samples = ArrayDeque<Sample>()
    var offsetNs = 0L
        private set
    var rttMs = Double.NaN
        private set
    var hasOffset = false
        private set

    init { require(window >= 1 && t1Window >= 1) }

    @Synchronized fun noteSentT1(t1: Long) {
        sentT1.addLast(t1)
        if (sentT1.size > t1Window) sentT1.removeFirst()
    }

    @Synchronized fun sentT1Matches(t1: Long): Boolean = sentT1.contains(t1)

    /** Returns true when [t1] matched a recently-sent stats timestamp. */
    @Synchronized fun onSyncResponse(t1: Long, t2: Long, t3: Long, t4: Long, nowMs: Long): Boolean {
        purge(nowMs)
        if (!sentT1.contains(t1)) return false
        val rtt = (t4 - t1) - (t3 - t2)
        if (rtt < 0) return false
        samples.addLast(Sample(((t2 - t1) + (t3 - t4)) / 2, rtt, nowMs))
        while (samples.size > window) samples.removeFirst()
        reselect()
        return true
    }

    /** Coarse fallback from "hostNow" while no sync exchange has completed. */
    @Synchronized fun onHostNow(hostNowNs: Long, androidNowNs: Long, nowMs: Long) {
        purge(nowMs)
        if (!hasOffset) {
            offsetNs = hostNowNs - androidNowNs
            rttMs = Double.NaN
            hasOffset = true
        }
    }

    private fun reselect() {
        val best = samples.minByOrNull { it.rttNs } ?: return
        offsetNs = best.thetaNs
        rttMs = best.rttNs / 1e6
        hasOffset = true
    }

    @Synchronized fun purge(nowMs: Long) {
        samples.removeAll { nowMs - it.atMs > maxAgeMs }
        if (samples.isEmpty()) {
            hasOffset = false
            offsetNs = 0L
            rttMs = Double.NaN
        } else {
            reselect()
        }
    }
}

/**
 * Input transit measurement: outgoing 0x02 events are stamped with "ts"
 * (android uptime ns) and remembered; the host echoes {ts, arr} probes and
 * transit = (arr − (ts + clockOffset)) using the host clock offset. Only the
 * event type is retained — never text or keycodes.
 */
class InputTransit(private val window: Int = 32) {
    private class Sent(val tsNs: Long, val type: String?)

    private val sent = ArrayDeque<Sent>()
    private var lastMsValue = Double.NaN
    private var maxMsValue = Double.NaN

    init { require(window >= 1) }

    @Synchronized fun noteSent(tsNs: Long, type: String?) {
        sent.addLast(Sent(tsNs, type))
        if (sent.size > window) sent.removeFirst()
    }

    /** Returns the transit in ms, or null when [ts] does not match a recent send. */
    @Synchronized fun onProbe(tsNs: Long, arrNs: Long, clockOffsetNs: Long): Double? {
        val index = sent.indexOfFirst { it.tsNs == tsNs }
        if (index < 0) return null
        sent.removeAt(index)
        val ms = (arrNs - (tsNs + clockOffsetNs)) / 1e6
        if (ms in 0.0..RenderTiming.SANITY_MAX_MS) {
            lastMsValue = ms
            maxMsValue = if (maxMsValue.isNaN()) ms else maxOf(maxMsValue, ms)
        }
        return ms
    }

    @Synchronized fun lastMs(): Double = lastMsValue
    @Synchronized fun maxMs(): Double = maxMsValue
}

/**
 * Per-connection aggregation of all latency measurements: the 0x05 → render
 * FIFO, NTP-lite clock sync, and input transit. Clocks are injected so the
 * pure logic stays unit-testable.
 */
class LatencyTracker(
    private val uptimeNs: () -> Long = { android.os.SystemClock.uptimeMillis() * 1_000_000L },
    private val nowMs: () -> Long = { android.os.SystemClock.uptimeMillis() }
) {
    val renderTiming = RenderTiming()
    val clock = ClockSync()
    val input = InputTransit()
    private val stash = VideoTimingStash()

    /** 0x05 payload: {"seq":Int, "cap":Double host uptime ns, "enc":Double}. */
    fun onVideoTiming(json: JSONObject) {
        runCatching {
            stash.stash(FrameTiming(json.getLong("seq"), json.getDouble("cap").toLong(), json.getDouble("enc").toLong()))
        }
    }

    /** Returns the timing stashed by the 0x05 preceding a 0x01 frame (null if none). */
    fun takeVideoTiming(): FrameTiming? = stash.take()

    /** Resync the render FIFO (e.g. decoder restarted after a surface change). */
    fun resetRenderTiming() = renderTiming.clear()

    /** Adds "ts" (android uptime ns) to an outgoing 0x02 event unless the caller stamped the event time already. */
    fun stampOutgoingInput(json: JSONObject) {
        if (!json.has("ts")) json.put("ts", uptimeNs())
        input.noteSent(json.getLong("ts"), json.optString("t"))
    }

    /** Adds "t1" (android uptime ns) to outgoing 0x03 stats and remembers it for the sync exchange. */
    fun stampOutgoingStats(json: JSONObject) {
        val t1 = uptimeNs()
        json.put("t1", t1)
        clock.noteSentT1(t1)
    }

    /** Incoming host 0x03 stats: may carry "sync"{t1,t2,t3}, "hostNow", "inProbe"{ts,arr}. */
    fun onHostStats(json: JSONObject) {
        val t4 = uptimeNs()
        val atMs = nowMs()
        val sync = json.optJSONObject("sync")
        if (sync != null) {
            runCatching {
                clock.onSyncResponse(sync.getLong("t1"), sync.getLong("t2"), sync.getLong("t3"), t4, atMs)
            }
        }
        if (json.has("hostNow")) {
            runCatching { clock.onHostNow(json.getDouble("hostNow").toLong(), t4, atMs) }
        }
        val probe = json.optJSONObject("inProbe")
        if (probe != null) {
            runCatching { input.onProbe(probe.getLong("ts"), probe.getDouble("arr").toLong(), clock.offsetNs) }
        }
    }
}
