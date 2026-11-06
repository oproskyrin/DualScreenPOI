package com.oleg.dualscreen

import org.json.JSONObject

/** UI-thread state, deliberately independent of Android for regression tests. */
class PhysicalInputState {
    private val keys = mutableMapOf<Pair<Int, Int>, Long>()
    private var resetAt = Long.MIN_VALUE
    private var buttons = 0
    private var blockedButtons = 0
    fun key(device: Int, code: Int, down: Boolean, repeat: Int, meta: Int, downTime: Long, text: String?): JSONObject? {
        val id = device to code
        if (down) {
            if (downTime <= resetAt || (repeat > 0 && keys[id] != downTime) || (repeat == 0 && keys[id] == downTime)) return null
            keys[id] = downTime
        } else {
            if (keys[id] != downTime) return null
            keys.remove(id)
        }
        return JSONObject().put("t", "hardwareKey").put("code", code).put("down", down)
            .put("repeat", repeat).put("meta", meta).apply {
                if (down && meta and SHORTCUT_META == 0 && !text.isNullOrEmpty() && text.length <= 16 && text.none { Character.isISOControl(it) }) put("text", text)
            }
    }
    fun reset(now: Long): JSONObject {
        keys.clear(); blockedButtons = blockedButtons or buttons; buttons = 0; resetAt = maxOf(resetAt, now)
        return JSONObject().put("t", "inputReset")
    }
    /** Reconcile both touch and generic button events; their duplicate pair is harmless. */
    fun pointer(action: String, mask: Int, freshPress: Boolean, x: Double, y: Double, meta: Int, dx: Double = 0.0, dy: Double = 0.0): List<JSONObject> {
        if (!x.isFinite() || !y.isFinite()) return emptyList()
        fun event(a: String) = JSONObject().put("t", "pointer").put("action", a)
            .put("x", x.coerceIn(0.0, 1.0)).put("y", y.coerceIn(0.0, 1.0)).put("meta", meta)
        val result = mutableListOf<JSONObject>()
        blockedButtons = blockedButtons and mask
        for ((bit, name) in listOf(1 to "left", 2 to "right", 4 to "middle")) {
            val was = buttons and bit != 0
            val held = mask and bit != 0
            if (was && !held) { buttons = buttons and bit.inv(); result.add(event("up").put("button", name)) }
            if (!was && held && freshPress && blockedButtons and bit == 0) { buttons = buttons or bit; result.add(event("down").put("button", name)) }
        }
        if (action == "move") result.add(event("move"))
        if (action == "scroll" && dx.isFinite() && dy.isFinite()) result.add(event("scroll").put("dx", dx).put("dy", dy))
        return result
    }
    companion object {
        /** Android axes are positive up/right; legacy DSXP is content-drag direction. */
        fun scrollTicks(horizontal: Double, vertical: Double) = -horizontal to -vertical
        // Android normalized CTRL, ALT (including directional bits), META masks.
        const val SHORTCUT_META = 0x7000 or 0x70000 or 0x32
        fun eligible(streaming: Boolean, enabled: Boolean, focused: Boolean, nativeUi: Boolean, hardware: Boolean, code: Int): Boolean =
            streaming && enabled && focused && !nativeUi && hardware &&
                (code in 7..16 || code in 19..22 || code in 29..62 || code in 66..76 || code in 92..93 ||
                    code in 111..115 || code in 117..119 || code in 122..124 || code in 131..161)
    }
}
