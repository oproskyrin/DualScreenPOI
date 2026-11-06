package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class AccessUnitQueueTest {

    private fun au(s: String) = s.toByteArray()

    @Test fun `overflow drops the oldest delta frame and keeps keyframes`() {
        val q = AccessUnitQueue(2)
        q.offer(au("k1"), true)
        q.offer(au("d1"), false)
        q.offer(au("d2"), false) // full: d1 is the oldest non-keyframe -> dropped
        assertEquals(2, q.size())
        assertEquals(1L, q.dropped)
        val first = q.poll()
        val second = q.poll()
        assertEquals("k1", String(first!!.data))
        assertTrue(first.keyframe)
        assertEquals("d2", String(second!!.data))
        assertFalse(second.keyframe)
    }

    @Test fun `incoming keyframe evicts a delta even when the queue is full`() {
        val q = AccessUnitQueue(2)
        q.offer(au("d1"), false)
        q.offer(au("d2"), false)
        q.offer(au("k1"), true) // full: evicts oldest delta d1, queue = d2,k1
        assertEquals(2, q.size())
        assertEquals("d2", String(q.poll()!!.data))
        val k = q.poll()!!
        assertEquals("k1", String(k.data))
        assertTrue(k.keyframe)
    }

    @Test fun `keyframes are never dropped while any delta is queued`() {
        val q = AccessUnitQueue(3)
        q.offer(au("k1"), true)
        q.offer(au("k2"), true)
        q.offer(au("d1"), false)
        q.offer(au("k3"), true) // d1 evicted, all keyframes survive
        assertEquals(3, q.size())
        val drained = listOf(q.poll(), q.poll(), q.poll()).filterNotNull()
        assertEquals(listOf("k1", "k2", "k3"), drained.map { String(it.data) })
        assertTrue(drained.all { it.keyframe })
    }

    @Test fun `falls back to the oldest entry when everything queued is a keyframe`() {
        val q = AccessUnitQueue(2)
        q.offer(au("k1"), true)
        q.offer(au("k2"), true)
        q.offer(au("k3"), true) // all keyframes: oldest still has to go
        assertEquals(2, q.size())
        assertEquals(1L, q.dropped)
        assertEquals("k2", String(q.poll()!!.data))
        assertEquals("k3", String(q.poll()!!.data))
    }

    @Test fun `fifo order is preserved when nothing overflows`() {
        val q = AccessUnitQueue(4)
        q.offer(au("a"), false)
        q.offer(au("b"), true)
        q.offer(au("c"), false)
        assertEquals(listOf("a", "b", "c"), listOf(q.poll(), q.poll(), q.poll()).filterNotNull().map { String(it.data) })
        assertEquals(0L, q.dropped)
    }

    @Test fun `poll on empty queue returns null and clear empties everything`() {
        val q = AccessUnitQueue(2)
        assertNull(q.poll())
        q.offer(au("x"), false)
        q.offer(au("y"), false)
        q.clear()
        assertEquals(0, q.size())
        assertNull(q.poll())
        assertEquals(0L, q.dropped)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `capacity below one is rejected`() {
        AccessUnitQueue(0)
    }
}
