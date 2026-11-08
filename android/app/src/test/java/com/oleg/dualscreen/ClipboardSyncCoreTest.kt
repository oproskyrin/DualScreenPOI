package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class ClipboardSyncCoreTest {

    private fun coreWithClock() = object {
        var now = 10_000L
        val core = ClipboardSyncCore { now }
        fun advance(ms: Long) { now += ms }
    }

    // ------------------------------------------------------------------ hash

    @Test fun `hash16 matches sha256 first 16 hex chars`() {
        assertEquals("2cf24dba5fb0a30e", ClipboardSyncCore.hash16("hello"))
        assertEquals("e3b0c44298fc1c14", ClipboardSyncCore.hash16(""))
        // UTF-8 bytes, not UTF-16 code units.
        assertEquals("830d1964dc867318", ClipboardSyncCore.hash16("Привет мир"))
    }

    @Test fun `hash16 is stable and distinguishes texts`() {
        assertNotEquals(ClipboardSyncCore.hash16("a"), ClipboardSyncCore.hash16("b"))
        assertEquals(ClipboardSyncCore.hash16("повтор"), ClipboardSyncCore.hash16("повтор"))
    }

    // ------------------------------------------------------- outgoing: dedup

    @Test fun `first local change sends, identical repeat is an echo`() {
        val c = coreWithClock()
        val first = c.core.onLocalChange("первый") as ClipboardSyncCore.LocalDecision.Send
        assertEquals("первый", first.text)
        assertEquals(ClipboardSyncCore.hash16("первый"), first.hash)
        assertTrue(c.core.onLocalChange("первый") is ClipboardSyncCore.LocalDecision.Echo)
    }

    @Test fun `empty local clip never sends`() {
        val c = coreWithClock()
        assertTrue(c.core.onLocalChange("") is ClipboardSyncCore.LocalDecision.Echo)
    }

    // ------------------------------------------------------ outgoing: cap

    @Test fun `oversized text is dropped without sending`() {
        val c = coreWithClock()
        val big = "x".repeat(ClipboardSyncCore.MAX_BYTES) // exactly at the cap
        assertTrue(c.core.onLocalChange(big) is ClipboardSyncCore.LocalDecision.Send)
        assertTrue(c.core.onLocalChange(big + "y") is ClipboardSyncCore.LocalDecision.Oversized)
    }

    // ----------------------------------------------- outgoing: rate limiting

    @Test fun `second change within the rate window is limited, latest wins after`() {
        val c = coreWithClock()
        assertTrue(c.core.onLocalChange("one") is ClipboardSyncCore.LocalDecision.Send)
        // A different clip 100 ms later: rate limited, nothing sent.
        c.advance(100)
        assertTrue(c.core.onLocalChange("two") is ClipboardSyncCore.LocalDecision.RateLimited)
        // After the window the *current* clip goes out — latest clip wins.
        c.advance(200)
        val sent = c.core.onLocalChange("two") as ClipboardSyncCore.LocalDecision.Send
        assertEquals("two", sent.text)
        // And the very next identical read is an echo.
        assertTrue(c.core.onLocalChange("two") is ClipboardSyncCore.LocalDecision.Echo)
    }

    @Test fun `retry inside the window never bypasses the rate limit`() {
        val c = coreWithClock()
        assertTrue(c.core.onLocalChange("a") is ClipboardSyncCore.LocalDecision.Send)
        c.advance(1)
        assertTrue(c.core.onLocalChange("b") is ClipboardSyncCore.LocalDecision.RateLimited)
        c.advance(1)
        assertTrue(c.core.onLocalChange("b") is ClipboardSyncCore.LocalDecision.RateLimited)
        c.advance(298) // exactly 300 ms after the send → allowed again
        val sent = c.core.onLocalChange("b") as ClipboardSyncCore.LocalDecision.Send
        assertEquals("b", sent.text)
    }

    // -------------------------------------------------------- incoming: dedup

    @Test fun `incoming unknown hash applies, repeat hash is skipped`() {
        val c = coreWithClock()
        assertTrue(c.core.onIncoming("текст", "aaaaaaaaaaaaaaaa"))
        assertFalse(c.core.onIncoming("текст", "aaaaaaaaaaaaaaaa"))
    }

    @Test fun `incoming empty text never applies`() {
        val c = coreWithClock()
        assertFalse(c.core.onIncoming("", "aaaaaaaaaaaaaaaa"))
    }

    // ----------------------------------------------------- full loop, both ways

    @Test fun `incoming clip suppresses the local echo of the applied set`() {
        val c = coreWithClock()
        // Mac → tablet: host sends hash H.
        val hash = ClipboardSyncCore.hash16("с Mac")
        assertTrue(c.core.onIncoming("с Mac", hash))
        // setPrimaryClip fires the local listener; the hash matches and stays silent.
        assertTrue(c.core.onLocalChange("с Mac") is ClipboardSyncCore.LocalDecision.Echo)
    }

    @Test fun `local send suppresses the incoming echo`() {
        val c = coreWithClock()
        val sent = c.core.onLocalChange("на Mac") as ClipboardSyncCore.LocalDecision.Send
        // Host echoes the same hash back (pasteboard round trip).
        assertFalse(c.core.onIncoming(sent.text, sent.hash))
    }

    @Test fun `new text after an applied incoming clip is sent out`() {
        val c = coreWithClock()
        assertTrue(c.core.onIncoming("old", "bbbbbbbbbbbbbbbb"))
        c.advance(400)
        val sent = c.core.onLocalChange("new") as ClipboardSyncCore.LocalDecision.Send
        assertEquals("new", sent.text)
        // The host echo of the same text is skipped both ways.
        assertTrue(c.core.onLocalChange("new") is ClipboardSyncCore.LocalDecision.Echo)
        assertFalse(c.core.onIncoming(sent.text, sent.hash))
    }
}
