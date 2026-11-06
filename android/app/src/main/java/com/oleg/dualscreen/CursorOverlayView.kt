package com.oleg.dualscreen

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.view.View

/**
 * Draw-only local cursor rendered on top of the video SurfaceView. It never
 * intercepts touches: the view is not clickable and returns false from
 * touch handling, so dispatch falls through to the SurfaceView beneath it.
 * Thin white arrow (~24dp) with a dark outline for visibility on any frame.
 */
class CursorOverlayView(context: Context) : View(context) {

    private val state = LocalCursorState()
    private val density = resources.displayMetrics.density
    private val sizePx = 24f * density
    private val outlinePx = 1.5f * density

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        style = Paint.Style.FILL
    }
    private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6000000.toInt()
        style = Paint.Style.STROKE
        strokeWidth = outlinePx
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
    }
    private val arrow = Path()

    init {
        setWillNotDraw(false)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun show(x: Float, y: Float) {
        state.onDown(x, y)
        invalidate()
    }

    fun move(x: Float, y: Float) {
        if (!state.visible) return
        state.onMove(x, y)
        invalidate()
    }

    fun hide() {
        if (!state.visible) return
        state.onUp()
        invalidate()
    }

    fun setCursorEnabled(enabled: Boolean) {
        state.enable(enabled)
        invalidate()
    }

    public override fun onDraw(canvas: Canvas) {
        if (!state.visible) return
        val scale = sizePx / 17f // arrow geometry spans ~17 units
        arrow.rewind()
        arrow.moveTo(0f, 0f)
        arrow.lineTo(0f, 16.9f)
        arrow.lineTo(4.2f, 13.1f)
        arrow.lineTo(6.6f, 18.2f)
        arrow.lineTo(8.7f, 17.3f)
        arrow.lineTo(6.3f, 12.3f)
        arrow.lineTo(11.1f, 11.9f)
        arrow.close()
        canvas.save()
        canvas.translate(state.x, state.y)
        canvas.scale(scale, scale)
        canvas.drawPath(arrow, outline)
        canvas.drawPath(arrow, fill)
        canvas.restore()
    }
}
