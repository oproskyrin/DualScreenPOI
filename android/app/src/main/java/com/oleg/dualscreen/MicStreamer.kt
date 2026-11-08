package com.oleg.dualscreen

/**
 * Microphone capture for DSXP 0x07 frames (docs/mic-0x07.md).
 *
 * Android-free state machine: the capture device is injected behind
 * [MicRecorder], so frame math, start/stop idempotency and the
 * permission-denied path run in plain JVM unit tests. The Android
 * implementation of the recorder lives in AudioRecordMicRecorder.
 *
 * Frames of exactly [frameBytes] (~20 ms at 48 kHz mono PCM16) are read on
 * a dedicated thread and handed to [sender] (DsxpConnection.sendMic —
 * executor path, non-blocking). When the sender reports a backed-up queue
 * the frame is dropped: capture never accumulates audio. Callers log sizes
 * and counters only — audio bytes never reach the log and never leave this
 * class except through [sender].
 */
class MicStreamer(
    private val frameBytes: Int = frameBytes(),
    private val recorder: MicRecorder,
    private val sender: (ByteArray) -> Boolean,
    private val logEvent: (String) -> Unit = {}
) {
    /** Capture device behind an interface so tests substitute a fake. */
    interface MicRecorder {
        /** Begin capturing; false when the device refuses (busy, missing, …). */
        fun start(): Boolean
        /** Blocking read filling up to buffer.size bytes; returns <=0 on end/error. */
        fun read(buffer: ByteArray): Int
        /** Release the device; safe from any state, thread and repeat call. */
        fun stop()
    }

    companion object {
        const val SAMPLE_RATE = 48_000
        const val FRAME_MS = 20

        /** 48 kHz mono PCM16, ~20 ms: 48000 · 2 bytes · 20 ms = 1920. */
        fun frameBytes(sampleRateHz: Int = SAMPLE_RATE, frameMs: Int = FRAME_MS): Int =
            sampleRateHz * 2 * frameMs / 1000
    }

    /** Set only when the RECORD_AUDIO grant exists; never opens the mic otherwise. */
    @Volatile var permissionGranted = false

    private val stateLock = Any()
    private var running = false
    private var generation = 0L
    private var thread: Thread? = null
    val isRunning: Boolean get() = synchronized(stateLock) { running }

    @Volatile var framesSent: Long = 0L
        private set
    @Volatile var framesDropped: Long = 0L
        private set

    /**
     * Idempotent. Refuses (false, no recorder open, no thread) without the
     * runtime permission — the denied path must never touch the device.
     */
    fun start(): Boolean {
        synchronized(stateLock) {
            if (running) return true
            if (!permissionGranted) {
                logEvent("mic start refused reason=no-permission")
                return false
            }
            if (!recorder.start()) {
                logEvent("mic start failed reason=recorder")
                return false
            }
            running = true
            generation++
            val gen = generation
            logEvent("mic capture started frameBytes=$frameBytes")
            val t = Thread({ captureLoop(gen) }, "dsxp-mic")
            thread = t
            t.start()
            return true
        }
    }

    /** Idempotent; releases the device first so a parked read() returns. */
    fun stop() {
        synchronized(stateLock) {
            if (!running) return
            running = false
            generation++
        }
        val t = thread
        thread = null
        recorder.stop()
        t?.join(1000)
    }

    private fun captureLoop(gen: Long) {
        val buffer = ByteArray(frameBytes)
        var dropping = false
        try {
            while (true) {
                val alive = synchronized(stateLock) { running && generation == gen }
                if (!alive) break
                val n = try {
                    recorder.read(buffer)
                } catch (e: Exception) {
                    logEvent("mic read failed ${e.javaClass.simpleName}")
                    break
                }
                if (n <= 0) break
                if (n != frameBytes) continue // discard a partial frame
                // Fresh copy per frame: the send executor touches the payload
                // after this loop has already refilled the buffer.
                if (sender(buffer.copyOf(n))) {
                    framesSent++
                    dropping = false
                } else {
                    framesDropped++
                    if (!dropping) { dropping = true; logEvent("mic send dropped reason=backlog") }
                }
            }
        } finally {
            recorder.stop() // no-op when stop() already released the device
            synchronized(stateLock) {
                if (generation == gen) { running = false; thread = null }
            }
            logEvent("mic capture stopped sent=$framesSent dropped=$framesDropped")
        }
    }
}
