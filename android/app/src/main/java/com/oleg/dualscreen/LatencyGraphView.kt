package com.oleg.dualscreen

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View

/**
 * Sparkline of the recent capture->render samples (ms): one bar per sample,
 * green when within the target band, yellow when elevated, red on a backlog.
 * A thin guide line marks the 40 ms band edge; the axis label is the scale
 * maximum. Empty until the clock is synced and real samples exist.
 */
class LatencyGraphView(context: Context) : View(context) {
    private var samples: List<Double> = emptyList()
    private var maxMs = 60.0
    private val bar = Paint(Paint.ANTI_ALIAS_FLAG)
    private val guide = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x40FFFFFF; strokeWidth = 1f
    }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x99FFFFFF.toInt(); textSize = 22f
    }

    fun setSamples(values: List<Double>) {
        samples = values
        val peak = (values.maxOrNull() ?: 60.0).coerceAtLeast(60.0)
        // Round the scale up to the next 20 ms so the axis stays readable.
        maxMs = ((peak / 20.0).toInt() + 1) * 20.0
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (samples.isEmpty()) return
        val scale = h / maxMs
        val gap = 2f
        val n = samples.size
        val bw = ((w - gap * (n - 1)) / n).coerceAtLeast(1f)
        samples.forEachIndexed { i, ms ->
            val bh = (ms * scale).toFloat().coerceIn(2f, h)
            bar.color = when {
                ms <= 40.0 -> 0xCC4ADE80.toInt()
                ms <= 70.0 -> 0xCCFACC15.toInt()
                else -> 0xCCF87171.toInt()
            }
            val x = i * (bw + gap)
            canvas.drawRect(x, h - bh, x + bw, h, bar)
        }
        val guideY = h - (40.0 * scale).toFloat()
        if (guideY > 0f) canvas.drawLine(0f, guideY, w, guideY, guide)
        canvas.drawText(context.getString(R.string.graph_milliseconds, maxMs.toInt()), 8f, 34f, label)
    }
}
