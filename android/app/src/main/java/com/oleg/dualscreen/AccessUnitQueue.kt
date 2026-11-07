package com.oleg.dualscreen

/**
 * Bounded FIFO of pending access units for the async decoder. [offer] never
 * blocks and never grows past [capacity]: when full, the oldest non-keyframe
 * is dropped so a keyframe (needed to resume decoding after drops) survives.
 * If everything queued is a keyframe, the oldest one still goes — a bounded
 * queue must always accept the newest frame.
 */
class AccessUnitQueue(private val capacity: Int) {

    class Frame(val data: ByteArray, val keyframe: Boolean, val tag: Any? = null)

    private val frames = ArrayDeque<Frame>()

    /** Number of frames dropped due to overflow. */
    var dropped: Long = 0
        private set

    init {
        require(capacity >= 1) { "capacity must be >= 1" }
    }

    @Synchronized
    fun offer(data: ByteArray, keyframe: Boolean, tag: Any? = null) {
        if (frames.size >= capacity) {
            val victim = frames.indexOfFirst { !it.keyframe }
            if (victim >= 0) frames.removeAt(victim) else frames.removeFirst()
            dropped++
        }
        frames.addLast(Frame(data, keyframe, tag))
    }

    @Synchronized
    fun poll(): Frame? = frames.removeFirstOrNull()

    @Synchronized
    fun size(): Int = frames.size

    @Synchronized
    fun clear() = frames.clear()
}
