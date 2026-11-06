package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class FloatingPanelPositionTest {
    @Test fun `drag stays inside the screen and round trips normalized position`() {
        val bounds = FloatingPanelPosition(1000f, 600f, 56f, 56f, 12f)
        assertEquals(932f, bounds.x(1f), 0.001f)
        assertEquals(12f, bounds.y(0f), 0.001f)
        assertEquals(0f, bounds.fractionX(-100f), 0.001f)
        assertEquals(1f, bounds.fractionY(900f), 0.001f)
        assertEquals(0.35f, bounds.fractionX(bounds.x(0.35f)), 0.001f)
    }

    @Test fun `saved position adapts to resized screens and rejects invalid coordinates`() {
        val portrait = FloatingPanelPosition(600f, 1000f, 56f, 56f, 12f)
        assertEquals(532f, portrait.x(1f), 0.001f)
        assertEquals(12f, portrait.y(Float.NaN), 0.001f)
        val tiny = FloatingPanelPosition(20f, 20f, 56f, 56f, 12f)
        assertEquals(0f, tiny.x(1f), 0.001f)
        assertEquals(0f, tiny.fractionX(100f), 0.001f)
    }
}
