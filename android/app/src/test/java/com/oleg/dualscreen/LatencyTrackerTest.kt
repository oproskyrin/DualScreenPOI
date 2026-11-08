package com.oleg.dualscreen

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LatencyTrackerTest {

    // ---------------------------------------------------------------- stash

    @Test fun `stash then take returns timing and clears`() {
        val s = VideoTimingStash()
        s.stash(FrameTiming(7, 1_000, 1_100))
        val t = s.take()
        assertNotNull(t)
        assertEquals(7L, t!!.seq)
        assertEquals(1_000L, t.capNs)
        assertEquals(1_100L, t.encNs)
        assertNull(s.take())
    }

    @Test fun `take without stash returns null`() {
        assertNull(VideoTimingStash().take())
    }

    @Test fun `second 0x05 before 0x01 overwrites the first (host skip tolerated)`() {
        val s = VideoTimingStash()
        s.stash(FrameTiming(1, 10, 20))
        s.stash(FrameTiming(3, 30, 40)) // seq 2 skipped by the host entirely
        assertEquals(3L, s.take()!!.seq)
        assertNull(s.take())
    }

    // -------------------------------------------------------- render timing

    @Test fun `rendered results follow FIFO push order`() {
        val r = RenderTiming()
        r.push(capNs = 1_000_000, encNs = 1_100_000, submitNs = 0)
        r.push(capNs = 2_000_000, encNs = 2_100_000, submitNs = 0)
        r.push(capNs = 3_000_000, encNs = 3_100_000, submitNs = 0)
        r.onRendered(nowNs = 5_000_000, clockOffsetNs = 0)
        assertEquals(4.0, r.lastCapToRenderMs(), 1e-9)
        assertEquals(3.9, r.lastEncToRenderMs(), 1e-9)
        r.onRendered(nowNs = 6_000_000, clockOffsetNs = 0)
        assertEquals(4.0, r.lastCapToRenderMs(), 1e-9)
        r.onRendered(nowNs = 7_000_000, clockOffsetNs = 0)
        assertEquals(4.0, r.lastCapToRenderMs(), 1e-9)
    }

    @Test fun `render applies the clock offset`() {
        val r = RenderTiming()
        r.push(capNs = 1_000_000, encNs = 1_000_000, submitNs = 0)
        // θ=+0.5ms: host clock runs 0.5ms AHEAD of android. Converting the
        // android render time into the host domain ADDS θ: (5 + 0.5) − 1 = 4.5.
        r.onRendered(nowNs = 5_000_000, clockOffsetNs = 500_000)
        assertEquals(4.5, r.lastCapToRenderMs(), 1e-9)
        // Negative θ (host uptime behind android uptime, e.g. recent reboot):
        r.push(capNs = 1_000_000, encNs = 1_000_000, submitNs = 0)
        r.onRendered(nowNs = 5_000_000, clockOffsetNs = -500_000)
        assertEquals(3.5, r.lastCapToRenderMs(), 1e-9)
    }

    @Test fun `bounded FIFO drops the oldest entry on overflow`() {
        val r = RenderTiming(capacity = 2)
        r.push(1_000_000, 1_000_000, 0)
        r.push(2_000_000, 2_000_000, 0)
        r.push(3_000_000, 3_000_000, 0) // evicts the first push
        assertEquals(2, r.pendingCount())
        r.onRendered(nowNs = 12_000_000, clockOffsetNs = 0)
        assertEquals(10.0, r.lastCapToRenderMs(), 1e-9) // from push #2, not push #1
    }

    @Test fun `render without a pending entry is a no-op`() {
        val r = RenderTiming()
        r.onRendered(nowNs = 1_000_000, clockOffsetNs = 0)
        assertTrue(r.lastCapToRenderMs().isNaN())
        assertEquals(0L, r.matchedFrames)
    }

    @Test fun `dropped output pops the FIFO without polluting stats`() {
        val r = RenderTiming()
        r.push(10_000_000, 10_000_000, 0) // will be dropped (never rendered)
        r.push(20_000_000, 20_000_000, 0) // will be rendered next
        r.onDropped()
        r.onRendered(nowNs = 30_000_000, clockOffsetNs = 0)
        assertEquals(10.0, r.lastCapToRenderMs(), 1e-9) // 30-20, pairing intact
        assertEquals(1L, r.matchedFrames) // drop is not counted as a render
        r.onDropped() // FIFO already empty: no-op
    }

    @Test fun `insane values update last but never pollute the average`() {
        val r = RenderTiming()
        r.push(10_000_000, 10_000_000, 0)
        r.onRendered(nowNs = 9_000_000, clockOffsetNs = 0) // −1ms: clock not sane
        assertEquals(-1.0, r.lastCapToRenderMs(), 1e-9)
        assertTrue(r.avgCapToRenderMs().isNaN())
        r.push(10_000_000, 10_000_000, 0)
        r.onRendered(nowNs = 20_000_000, clockOffsetNs = 0) // 10ms: sane
        assertEquals(10.0, r.lastCapToRenderMs(), 1e-9)
        assertEquals(10.0, r.avgCapToRenderMs(), 1e-9) // only the sane sample counted
    }

    @Test fun `average covers only the last N sane samples`() {
        val r = RenderTiming(history = 3)
        for (capMs in 1L..4L) {
            r.push(capMs * 1_000_000, capMs * 1_000_000, 0)
            r.onRendered(nowNs = 2 * capMs * 1_000_000, clockOffsetNs = 0)
        }
        // last three sane samples are 2,3,4 ms
        assertEquals(3.0, r.avgCapToRenderMs(), 1e-9)
        assertEquals(3.0, r.avgEncToRenderMs(), 1e-9)
    }

    // ------------------------------------------------------------ clock sync

    @Test fun `ntp-lite offset and rtt math`() {
        val c = ClockSync()
        c.noteSentT1(1_000)
        assertTrue(c.onSyncResponse(t1 = 1_000, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 0))
        // θ = ((1500−1000)+(1600−1200))/2 = 450 ; rtt = (1200−1000)−(1600−1500) = 100
        assertTrue(c.hasOffset)
        assertEquals(450L, c.offsetNs)
        assertEquals(0.0001, c.rttMs, 1e-12)
    }

    @Test fun `negative offset when host clock is behind`() {
        val c = ClockSync()
        c.noteSentT1(2_000)
        c.onSyncResponse(t1 = 2_000, t2 = 1_900, t3 = 2_000, t4 = 2_100, nowMs = 0)
        // θ = ((1900−2000)+(2000−2100))/2 = −100
        assertEquals(-100L, c.offsetNs)
        assertTrue(c.hasOffset)
    }

    @Test fun `sync with unknown t1 is rejected`() {
        val c = ClockSync()
        c.noteSentT1(1_000)
        assertFalse(c.onSyncResponse(t1 = 4_242, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 0))
        assertFalse(c.hasOffset)
    }

    @Test fun `the sample with the lowest rtt wins`() {
        val c = ClockSync()
        c.noteSentT1(1_000); c.noteSentT1(2_000); c.noteSentT1(3_000)
        // rtt 100ns, θ=450
        c.onSyncResponse(t1 = 1_000, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 0)
        assertEquals(450L, c.offsetNs)
        // rtt 300ns, θ=750 — worse rtt must not replace the offset
        c.onSyncResponse(t1 = 2_000, t2 = 2_900, t3 = 3_000, t4 = 2_400, nowMs = 0)
        assertEquals(450L, c.offsetNs)
        // rtt 20ns, θ=−60 — better rtt takes over
        c.onSyncResponse(t1 = 3_000, t2 = 2_950, t3 = 2_990, t4 = 3_060, nowMs = 0)
        assertEquals(-60L, c.offsetNs)
        assertEquals(0.00002, c.rttMs, 1e-12)
    }

    @Test fun `sample window keeps only the newest samples`() {
        val c = ClockSync(window = 2)
        c.noteSentT1(1_000); c.noteSentT1(2_000); c.noteSentT1(3_000)
        c.onSyncResponse(t1 = 1_000, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 0) // θ=450 rtt=100
        c.onSyncResponse(t1 = 2_000, t2 = 2_900, t3 = 3_000, t4 = 2_400, nowMs = 0) // θ=750 rtt=300
        c.onSyncResponse(t1 = 3_000, t2 = 2_950, t3 = 2_990, t4 = 3_060, nowMs = 0) // θ=−60 rtt=20; evicts the first
        assertEquals(-60L, c.offsetNs)
        // the first t1 echoed again: it still matches a sent t1, but the window
        // only holds {θ=−60, θ=450} afterwards and −60 keeps the lowest rtt
        c.onSyncResponse(t1 = 1_000, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 0)
        assertEquals(-60L, c.offsetNs)
    }

    @Test fun `purge drops samples older than the max age`() {
        val c = ClockSync(maxAgeMs = 1_000)
        c.noteSentT1(1_000)
        c.onSyncResponse(t1 = 1_000, t2 = 1_500, t3 = 1_600, t4 = 1_200, nowMs = 100)
        assertTrue(c.hasOffset)
        c.purge(nowMs = 300) // sample is 200ms old: kept
        assertTrue(c.hasOffset)
        c.purge(nowMs = 5_000) // sample is 4.9s old: dropped
        assertFalse(c.hasOffset)
    }

    @Test fun `sent t1 ring keeps only the last 8`() {
        val c = ClockSync(t1Window = 3)
        c.noteSentT1(10); c.noteSentT1(20); c.noteSentT1(30); c.noteSentT1(40)
        assertFalse(c.onSyncResponse(t1 = 10, t2 = 15, t3 = 15, t4 = 20, nowMs = 0)) // evicted
        assertTrue(c.onSyncResponse(t1 = 40, t2 = 45, t3 = 45, t4 = 50, nowMs = 0))
    }

    @Test fun `negative rtt sample is rejected`() {
        val c = ClockSync()
        c.noteSentT1(1_000)
        // t4−t1 = 200 but t3−t2 = 900 → rtt = −700
        assertFalse(c.onSyncResponse(t1 = 1_000, t2 = 5_000, t3 = 5_900, t4 = 1_200, nowMs = 0))
        assertFalse(c.hasOffset)
    }

    // --------------------------------------------------------- input transit

    @Test fun `transit math applies the clock offset`() {
        val t = InputTransit()
        t.noteSent(tsNs = 10_000, type = "move")
        val ms = t.onProbe(tsNs = 10_000, arrNs = 20_000, clockOffsetNs = 1_000)
        // (20000 − (10000 + 1000))/1e6 = 0.009ms
        assertEquals(0.009, ms!!, 1e-12)
        assertEquals(0.009, t.lastMs(), 1e-12)
        assertEquals(0.009, t.maxMs(), 1e-12)
    }

    @Test fun `probe with unknown ts returns null`() {
        assertNull(InputTransit().onProbe(tsNs = 1, arrNs = 2, clockOffsetNs = 0))
    }

    @Test fun `matched probe is consumed exactly once and max is tracked`() {
        val t = InputTransit()
        t.noteSent(1_000, "down"); t.noteSent(2_000, "move")
        assertEquals(1.999, t.onProbe(1_000, arrNs = 2_000_000, clockOffsetNs = 0)!!, 1e-9)
        assertEquals(4.998, t.onProbe(2_000, arrNs = 5_000_000, clockOffsetNs = 0)!!, 1e-9)
        assertNull(t.onProbe(1_000, arrNs = 9_000_000, clockOffsetNs = 0)) // already consumed
        assertEquals(4.998, t.lastMs(), 1e-9)
        assertEquals(4.998, t.maxMs(), 1e-9)
    }

    @Test fun `sent ring keeps only the last 32 entries`() {
        val t = InputTransit(window = 2)
        t.noteSent(1, "a"); t.noteSent(2, "b"); t.noteSent(3, "c")
        assertNull(t.onProbe(1, arrNs = 10, clockOffsetNs = 0))
        assertNotNull(t.onProbe(3, arrNs = 10, clockOffsetNs = 0))
    }

    @Test fun `insane transit values are ignored`() {
        val t = InputTransit()
        t.noteSent(1_000, "move")
        val ms = t.onProbe(1_000, arrNs = 1_000, clockOffsetNs = 0) // 0ms — degenerate but sane
        assertEquals(0.0, ms!!, 1e-12)
        t.noteSent(5_000, "move")
        t.onProbe(5_000, arrNs = 2_000, clockOffsetNs = 0) // negative: ignored
        assertEquals(0.0, t.lastMs(), 1e-12)
    }

    // ------------------------------------------------- facade + JSON wiring

    @Test fun `0x05 video timing JSON round-trips through the stash`() {
        val tracker = LatencyTracker(uptimeNs = { 1L }, nowMs = { 0L })
        tracker.onVideoTiming(JSONObject("""{"seq":7,"cap":1.0e12,"enc":1.1e12}"""))
        val t = tracker.takeVideoTiming()
        assertNotNull(t)
        assertEquals(7L, t!!.seq)
        assertEquals(1_000_000_000_000L, t.capNs)
        assertEquals(1_100_000_000_000L, t.encNs)
        assertNull(tracker.takeVideoTiming())
    }

    @Test fun `malformed 0x05 payload is ignored`() {
        val tracker = LatencyTracker(uptimeNs = { 1L }, nowMs = { 0L })
        tracker.onVideoTiming(JSONObject("{}"))
        assertNull(tracker.takeVideoTiming())
    }

    @Test fun `outgoing input is stamped with ts and remembered for probes`() {
        var now = 42L
        val tracker = LatencyTracker(uptimeNs = { now }, nowMs = { 0L })
        val json = JSONObject().put("t", "move").put("x", 0.5)
        tracker.stampOutgoingInput(json)
        assertEquals(42L, json.getLong("ts"))
        now = 100
        tracker.onHostStats(JSONObject("""{"inProbe":{"ts":42,"arr":2042}}"""))
        assertEquals(2.0e-3, tracker.input.lastMs(), 1e-12) // (2042−42)/1e6 ms with offset 0
    }

    @Test fun `pre-stamped input ts is kept and still recorded`() {
        val tracker = LatencyTracker(uptimeNs = { 999L }, nowMs = { 0L })
        val json = JSONObject().put("t", "down").put("ts", 7L) // eventTime from a MotionEvent
        tracker.stampOutgoingInput(json)
        assertEquals(7L, json.getLong("ts"))
        tracker.onHostStats(JSONObject("""{"inProbe":{"ts":7,"arr":1000007}}"""))
        assertEquals(1.0, tracker.input.lastMs(), 1e-9)
    }

    @Test fun `outgoing stats are stamped with t1 and sync completes the exchange`() {
        var now = 1_000L
        val tracker = LatencyTracker(uptimeNs = { now }, nowMs = { 0L })
        val json = JSONObject()
        tracker.stampOutgoingStats(json)
        val t1 = json.getLong("t1")
        assertEquals(1_000L, t1)
        now = 1_200 // t4 at arrival
        tracker.onHostStats(JSONObject("""{"sync":{"t1":$t1,"t2":1500,"t3":1600}}"""))
        assertTrue(tracker.clock.hasOffset)
        assertEquals(450L, tracker.clock.offsetNs)
    }

    @Test fun `sync with a foreign t1 does not produce an offset`() {
        val tracker = LatencyTracker(uptimeNs = { 1_000L }, nowMs = { 0L })
        val json = JSONObject()
        tracker.stampOutgoingStats(json)
        tracker.onHostStats(JSONObject("""{"sync":{"t1":777777,"t2":1500,"t3":1600}}"""))
        assertFalse(tracker.clock.hasOffset)
    }

    @Test fun `hostNow provides a coarse fallback before any sync`() {
        val tracker = LatencyTracker(uptimeNs = { 10_000L }, nowMs = { 0L })
        tracker.onHostStats(JSONObject("""{"hostNow":2.5e12}"""))
        assertTrue(tracker.clock.hasOffset)
        assertEquals(2_499_999_990_000L, tracker.clock.offsetNs)
    }

    @Test fun `full host stats message with sync and probe parses end to end`() {
        var now = 100L
        val tracker = LatencyTracker(uptimeNs = { now }, nowMs = { 0L })
        tracker.stampOutgoingStats(JSONObject())
        tracker.stampOutgoingInput(JSONObject().put("t", "drag").put("ts", 50))
        now = 200
        tracker.onHostStats(JSONObject("""
            {"sync":{"t1":100,"t2":300,"t3":350},"hostNow":1.0e12,
             "inProbe":{"ts":50,"arr":1000}}
        """.trimIndent()))
        // θ = ((300−100)+(350−200))/2 = 175
        assertTrue(tracker.clock.hasOffset)
        assertEquals(175L, tracker.clock.offsetNs)
        // transit = (1000 − (50 + 175))/1e6
        assertEquals((1000 - 225) / 1e6, tracker.input.lastMs(), 1e-12)
    }

    @Test fun `latency stats snapshot values stay finite or are omitted`() {
        val tracker = LatencyTracker(uptimeNs = { 1L }, nowMs = { 0L })
        val json = JSONObject()
        putFinite(json, "videoCapToRenderMs", tracker.renderTiming.lastCapToRenderMs()) // NaN
        putFinite(json, "decodeMs", 4.2)
        assertFalse(json.has("videoCapToRenderMs"))
        assertEquals(4.2, json.getDouble("decodeMs"), 1e-9)
    }
}
