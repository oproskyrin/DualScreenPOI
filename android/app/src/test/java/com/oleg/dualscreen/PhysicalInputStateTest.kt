package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class PhysicalInputStateTest {
    @Test fun resetSuppressesHeldButtonDuplicateUntilRelease() {
        val s = PhysicalInputState()
        assertEquals(1, s.pointer("button", 1, true, .2, .3, 0).size)
        s.reset(200)
        assertTrue(s.pointer("button", 1, true, .2, .3, 0).isEmpty())
        s.pointer("button", 0, false, .2, .3, 0)
        assertEquals("down", s.pointer("button", 1, true, .2, .3, 0).single().getString("action"))
    }
    @Test fun resetSuppressesOldDownRepeatAndUpButAllowsFreshPress() {
        val s = PhysicalInputState()
        s.key(1, 29, true, 0, 0, 100, "a")
        assertEquals("inputReset", s.reset(200).getString("t"))
        assertNull(s.key(1, 29, true, 1, 0, 100, "a"))
        assertNull(s.key(1, 29, true, 0, 0, 100, "a"))
        assertNull(s.key(1, 29, false, 0, 0, 100, null))
        assertNotNull(s.key(1, 29, true, 0, 0, 201, "a"))
    }
    @Test fun textIsDownOnlyPrintableBoundedAndNeverOnShortcuts() {
        for (meta in listOf(0x1000, 0x10000, 2, 0x10, 0x20)) {
            assertFalse(PhysicalInputState().key(1, 29, true, 0, meta, 1, "a")!!.has("text"))
        }
        for (text in listOf("\n", "x".repeat(17), "\u0000")) {
            assertFalse(PhysicalInputState().key(1, 29, true, 0, 0, 1, text)!!.has("text"))
        }
        assertEquals("Я", PhysicalInputState().key(1, 29, true, 0, 1, 1, "Я")!!.getString("text"))
    }
    @Test fun reservedKeysNativeUiAndImeAreNeverEligible() {
        for (code in listOf(3, 4, 24, 25, 26, 79, 82, 91, 164, 187)) {
            assertFalse(PhysicalInputState.eligible(true, true, true, false, true, code))
        }
        assertTrue(PhysicalInputState.eligible(true, true, true, false, true, 117))
        assertFalse(PhysicalInputState.eligible(false, true, true, false, true, 29))
        assertFalse(PhysicalInputState.eligible(true, false, true, false, true, 29))
        assertFalse(PhysicalInputState.eligible(true, true, false, false, true, 29))
        assertFalse(PhysicalInputState.eligible(true, true, true, true, true, 29))
        assertFalse(PhysicalInputState.eligible(true, true, true, false, false, 29))
    }
    @Test fun duplicateButtonsDragAllButtonsAndScrollAreNotSyntheticTaps() {
        val s = PhysicalInputState()
        assertEquals(listOf("left", "right", "middle"), s.pointer("button", 7, true, .5, .7, 0).map { it.getString("button") })
        assertTrue(s.pointer("button", 7, true, .5, .7, 0).isEmpty())
        assertEquals("move", s.pointer("move", 7, false, 2.0, -1.0, 0).single().getString("action"))
        assertEquals(3, s.pointer("button", 0, false, .5, .7, 0).size)
        val scroll = s.pointer("scroll", 0, false, .5, .7, 1, -2.0, 3.0).single()
        assertEquals(-2.0, scroll.getDouble("dx"), 0.0)
        assertEquals(3.0, scroll.getDouble("dy"), 0.0)
        assertTrue(s.pointer("move", 0, false, Double.NaN, 0.0, 0).isEmpty())
    }
    @Test fun staleReleaseCannotReleaseANewerPhysicalPress() {
        val s = PhysicalInputState()
        s.key(1, 29, true, 0, 0, 100, "a")
        s.reset(200)
        s.key(1, 29, true, 0, 0, 201, "a")
        assertNull(s.key(1, 29, false, 0, 0, 100, null))
        assertNotNull(s.key(1, 29, false, 0, 0, 201, null))
    }
    @Test fun onlyHostSupportedKeycodesAreIntercepted() {
        for (code in listOf(17, 18, 23, 63, 64, 65, 77, 116, 120, 121, 162, 163)) {
            assertFalse("unsupported Android key $code", PhysicalInputState.eligible(true, true, true, false, true, code))
        }
    }
    @Test fun androidScrollAxesBecomeLegacyDirectionalTicks() {
        assertEquals(-2.0 to 3.0, PhysicalInputState.scrollTicks(2.0, -3.0))
    }
    @Test fun forwardsOneDownRepeatsAndOneUp() {
        val s = PhysicalInputState()
        assertNotNull(s.key(1, 29, true, 0, 0, 100, "я"))
        assertNull(s.key(1, 29, true, 0, 0, 100, "я"))
        assertEquals(2, s.key(1, 29, true, 2, 0, 100, "я")!!.getInt("repeat"))
        assertFalse(s.key(1, 29, false, 0, 0, 100, "я")!!.has("text"))
        assertNull(s.key(1, 29, false, 0, 0, 100, null))
    }
}
