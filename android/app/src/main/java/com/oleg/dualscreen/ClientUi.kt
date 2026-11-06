package com.oleg.dualscreen

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.*

/** Small native-Views palette; no web view or heavyweight UI dependency. */
class ClientUi(private val context: Context) {
    val ink = Color.rgb(238, 242, 250)
    val muted = Color.rgb(158, 174, 194)
    val accent = Color.rgb(116, 221, 197)
    val background = Color.rgb(10, 16, 25)
    fun dp(value: Int) = (value * context.resources.displayMetrics.density).toInt()
    fun shape(color: Int, radius: Int = 20, border: Int = Color.rgb(43, 59, 76)) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat(); setStroke(dp(1), border)
    }
    fun column(padding: Int = 0) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
    }
    fun row() = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    fun text(value: String, size: Float = 16f, color: Int = ink, bold: Boolean = false) = TextView(context).apply {
        text = value; textSize = size; setTextColor(color)
        typeface = Typeface.create("sans-serif", if (bold) Typeface.BOLD else Typeface.NORMAL)
        setLineSpacing(dp(3).toFloat(), 1f)
    }
    fun label(parent: LinearLayout, value: String, size: Float = 16f, color: Int = ink, bold: Boolean = false): TextView {
        return text(value, size, color, bold).also { parent.addView(it, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) }) }
    }
    fun button(value: String, primary: Boolean = false, action: () -> Unit) = androidx.appcompat.widget.AppCompatButton(context).apply {
        text = value; contentDescription = value; isAllCaps = false; textSize = 15f
        setTextColor(if (primary) this@ClientUi.background else ink)
        background = shape(if (primary) accent else Color.rgb(27, 40, 55), 12)
        backgroundTintList = null
        minHeight = dp(52); minimumHeight = dp(52)
        setPadding(dp(18), dp(8), dp(18), dp(8))
        setOnClickListener { action() }
    }
    fun addButton(parent: LinearLayout, value: String, primary: Boolean = false, action: () -> Unit): Button {
        return button(value, primary, action).also {
            parent.addView(it, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        }
    }
    fun card() = column(24).apply { background = shape(Color.rgb(18, 28, 41)) }
    fun scroll(child: View) = ScrollView(context).apply { isFillViewport = true; addView(child) }
}
