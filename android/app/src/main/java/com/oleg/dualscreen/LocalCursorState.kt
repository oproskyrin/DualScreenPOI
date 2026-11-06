package com.oleg.dualscreen

/**
 * Pure state machine for the local touch cursor: visible from ACTION_DOWN
 * until ACTION_UP/ACTION_CANCEL, position follows the primary pointer.
 * No Android dependencies — unit-testable.
 */
class LocalCursorState(var enabled: Boolean = true) {

    var visible: Boolean = false
        private set

    var x: Float = 0f
        private set

    var y: Float = 0f
        private set

    fun onDown(x: Float, y: Float) {
        this.x = x
        this.y = y
        visible = enabled
    }

    /** Tracks the pointer only while a touch is active. */
    fun onMove(x: Float, y: Float) {
        if (!visible) return
        this.x = x
        this.y = y
    }

    fun onUp() { visible = false }

    fun onCancel() { visible = false }

    /** Toggling off mid-gesture hides the cursor immediately. */
    fun enable(on: Boolean) {
        enabled = on
        if (!on) visible = false
    }
}
