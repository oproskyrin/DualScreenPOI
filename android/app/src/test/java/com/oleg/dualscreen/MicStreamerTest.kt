package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

/**
 * Mic capture state machine (docs/mic-0x07.md): frame math, start/stop
 * idempotency, permission-denied path and drop-on-backlog behavior.
 * The capture device is faked — no Android audio classes on the JVM.
 */
class MicStreamerTest {

    /** Delivers a scripted sequence of read() results, then ends the loop. */
    private class ScriptedRecorder(vararg val script: Int) : MicStreamer.MicRecorder {
        var starts = 0
        var stops = 0
        private var next = 0
        override fun start(): Boolean { starts++; return true }
        override fun read(buffer: ByteArray): Int {
            if (next >= script.size) return -1
            return script[next++]
        }
        override fun stop() { stops++ }
    }

    /** Endless reads at a slow pace — for stop() and drop-path tests. */
    private class EndlessRecorder : MicStreamer.MicRecorder {
        var starts = 0
        var stops = 0
        override fun start(): Boolean { starts++; return true }
        override fun read(buffer: ByteArray): Int { Thread.sleep(1); return buffer.size }
        override fun stop() { stops++ }
    }

    private fun streamer(
        recorder: MicStreamer.MicRecorder,
        sender: (ByteArray) -> Boolean = { true },
        frameBytes: Int = MicStreamer.frameBytes(),
        log: MutableList<String> = mutableListOf()
    ): MicStreamer {
        val s = MicStreamer(frameBytes, recorder, sender) { log.add(it) }
        s.permissionGranted = true
        return s
    }

    /** Waits until the capture loop exits on its own (scripted end). */
    private fun awaitIdle(s: MicStreamer, ms: Long = 2000): Boolean {
        val deadline = System.currentTimeMillis() + ms
        while (s.isRunning && System.currentTimeMillis() < deadline) Thread.sleep(5)
        return !s.isRunning
    }

    // ------------------------------------------------------------ frame math

    @Test fun `frame size is 1920 bytes for 48 kHz mono pcm16 at 20 ms`() {
        assertEquals(1920, MicStreamer.frameBytes())
    }

    @Test fun `frame size math follows sample rate and frame duration`() {
        assertEquals(640, MicStreamer.frameBytes(16_000, 20))
        assertEquals(1764, MicStreamer.frameBytes(44_100, 20))
        assertEquals(3840, MicStreamer.frameBytes(48_000, 40))
        assertEquals(1920, MicStreamer.frameBytes(MicStreamer.SAMPLE_RATE, MicStreamer.FRAME_MS))
    }

    // ------------------------------------------------------ permission gate

    @Test fun `start is refused without permission and never opens the recorder`() {
        val rec = ScriptedRecorder()
        val log = mutableListOf<String>()
        val s = MicStreamer(MicStreamer.frameBytes(), rec, { true }) { log.add(it) }
        // permissionGranted stays false — the denied path.
        assertFalse(s.start())
        assertFalse(s.isRunning)
        assertEquals(0, rec.starts)
        assertEquals(0, rec.stops)
        assertTrue(log.any { it.contains("no-permission") })
    }

    @Test fun `recorder refusal keeps the stream stopped`() {
        val rec = object : MicStreamer.MicRecorder {
            var starts = 0
            override fun start(): Boolean { starts++; return false }
            override fun read(buffer: ByteArray): Int = -1
            override fun stop() {}
        }
        assertFalse(streamer(rec).start())
        assertEquals(1, rec.starts)
    }

    // ------------------------------------------------------- state machine

    @Test fun `start is idempotent and opens the recorder once`() {
        val rec = EndlessRecorder()
        val s = streamer(rec)
        assertTrue(s.start())
        assertTrue(s.start())
        assertEquals(1, rec.starts)
        s.stop()
    }

    @Test fun `stop is idempotent and releases the recorder`() {
        val rec = EndlessRecorder()
        val s = streamer(rec)
        assertTrue(s.start())
        s.stop()
        s.stop()
        assertFalse(s.isRunning)
        // stop() releases immediately, the exiting loop repeats it: the
        // recorder contract requires tolerance for repeat releases.
        assertTrue("stops=${rec.stops}", rec.stops >= 1)
    }

    @Test fun `restart after stop recaptures on the device`() {
        val rec = EndlessRecorder()
        val s = streamer(rec)
        assertTrue(s.start())
        s.stop()
        assertTrue(s.start())
        assertEquals(2, rec.starts)
        s.stop()
    }

    // -------------------------------------------------------------- capture

    @Test fun `whole frames are sent, partial frames are discarded`() {
        val rec = ScriptedRecorder(1920, 960, 1920, -1)
        val sent = java.util.Collections.synchronizedList(mutableListOf<ByteArray>())
        val s = streamer(rec, sender = { bytes -> sent.add(bytes); true })
        assertTrue(s.start())
        assertTrue(awaitIdle(s))
        assertEquals(2, s.framesSent)
        assertEquals(2, sent.size)
        assertTrue(sent.all { it.size == 1920 })
        assertEquals(0, s.framesDropped)
    }

    @Test fun `sender rejection drops frames instead of accumulating`() {
        val rec = EndlessRecorder()
        val s = streamer(rec, sender = { false })
        assertTrue(s.start())
        val deadline = System.currentTimeMillis() + 2000
        while (s.framesDropped == 0L && System.currentTimeMillis() < deadline) Thread.sleep(5)
        s.stop()
        assertEquals(0, s.framesSent)
        assertTrue("expected drops, got ${s.framesDropped}", s.framesDropped > 0)
        assertTrue("stops=${rec.stops}", rec.stops >= 1)
    }

    @Test fun `read error ends capture and stops the recorder`() {
        val rec = ScriptedRecorder(1920, -1)
        val s = streamer(rec)
        assertTrue(s.start())
        assertTrue(awaitIdle(s))
        assertFalse(s.isRunning)
        s.stop() // second stop after natural exit must stay safe
        assertEquals(1, rec.starts)
    }
}
