package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class LocalCursorStateTest {

    @Test fun `down shows the cursor and move tracks the pointer`() {
        val s = LocalCursorState()
        assertFalse(s.visible)
        s.onDown(10f, 20f)
        assertTrue(s.visible)
        assertEquals(10f, s.x, 0.001f)
        assertEquals(20f, s.y, 0.001f)
        s.onMove(30f, 40f)
        assertTrue(s.visible)
        assertEquals(30f, s.x, 0.001f)
        assertEquals(40f, s.y, 0.001f)
    }

    @Test fun `up and cancel hide the cursor`() {
        val s = LocalCursorState()
        s.onDown(1f, 2f)
        s.onUp()
        assertFalse(s.visible)
        s.onDown(3f, 4f)
        s.onCancel()
        assertFalse(s.visible)
    }

    @Test fun `move without an active touch is ignored`() {
        val s = LocalCursorState()
        s.onMove(5f, 5f)
        assertFalse(s.visible)
        assertEquals(0f, s.x, 0.001f)
        assertEquals(0f, s.y, 0.001f)
    }

    @Test fun `releasing and pressing again shows at the new position`() {
        val s = LocalCursorState()
        s.onDown(1f, 1f)
        s.onUp()
        s.onDown(99f, 88f)
        assertTrue(s.visible)
        assertEquals(99f, s.x, 0.001f)
        assertEquals(88f, s.y, 0.001f)
    }

    @Test fun `disabled cursor never becomes visible`() {
        val s = LocalCursorState(enabled = false)
        s.onDown(1f, 2f)
        assertFalse(s.visible)
    }

    @Test fun `disabling mid-gesture hides immediately and re-enabling needs a new down`() {
        val s = LocalCursorState()
        s.onDown(1f, 2f)
        assertTrue(s.visible)
        s.enable(false)
        assertFalse(s.visible)
        s.onMove(3f, 4f) // still hidden, position frozen
        assertFalse(s.visible)
        assertEquals(1f, s.x, 0.001f)
        s.enable(true)
        assertFalse(s.visible) // only a fresh ACTION_DOWN shows it
        s.onDown(7f, 8f)
        assertTrue(s.visible)
    }
}
