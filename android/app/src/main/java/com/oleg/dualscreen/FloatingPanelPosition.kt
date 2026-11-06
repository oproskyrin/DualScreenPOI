package com.oleg.dualscreen

/** Normalized handle placement survives resolution and orientation changes. */
class FloatingPanelPosition(
    private val width: Float,
    private val height: Float,
    private val handleWidth: Float,
    private val handleHeight: Float,
    private val margin: Float
) {
    private fun start(total: Float, handle: Float) = margin.coerceAtMost((total - handle).coerceAtLeast(0f) / 2f)
    private fun span(total: Float, handle: Float) = (total - handle - 2f * start(total, handle)).coerceAtLeast(0f)
    private fun normalized(value: Float) = if (value.isFinite()) value.coerceIn(0f, 1f) else 0f
    fun x(fraction: Float) = start(width, handleWidth) + normalized(fraction) * span(width, handleWidth)
    fun y(fraction: Float) = start(height, handleHeight) + normalized(fraction) * span(height, handleHeight)
    fun fractionX(x: Float) = fraction(x, width, handleWidth)
    fun fractionY(y: Float) = fraction(y, height, handleHeight)
    private fun fraction(value: Float, total: Float, handle: Float): Float {
        val available = span(total, handle)
        return if (available > 0f) normalized((value - start(total, handle)) / available) else 0f
    }
}
