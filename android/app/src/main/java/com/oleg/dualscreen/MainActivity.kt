package com.oleg.dualscreen

import android.annotation.SuppressLint
import android.graphics.Point
import android.os.Bundle
import android.view.Display
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import kotlin.math.abs

class MainActivity : AppCompatActivity(), DsxpConnection.Listener {

    private lateinit var surfaceView: SurfaceView
    private lateinit var controls: LinearLayout
    private lateinit var statusText: TextView
    private lateinit var addressEdit: EditText
    private lateinit var hzButton: Button

    private var connection: DsxpConnection? = null
    private var decoder: VideoDecoder? = null
    private var streaming = false

    private val hzOptions = intArrayOf(144, 120, 90, 60)
    private var hzIndex = 0
    private var pendingWidth = 0
    private var pendingHeight = 0

    // touch state
    private var touching = false
    private var twoFinger = false
    private var lastScroll = PointF0()

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        controls = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        statusText = TextView(this).apply { text = "DualScreen — подключение к Mac" }
        addressEdit = EditText(this).apply {
            hint = "host:port (127.0.0.1:7381 по USB)"
            setText("127.0.0.1:7381")
        }
        val connectButton = Button(this).apply { text = "Подключить" }
        hzButton = Button(this).apply { text = hzLabel() }
        controls.addView(statusText)
        controls.addView(addressEdit)
        controls.addView(connectButton)
        controls.addView(hzButton)
        val pad = (resources.displayMetrics.density * 16).toInt()
        controls.setPadding(pad, pad * 2, pad, pad)
        root.addView(controls, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        setContentView(root)

        connectButton.setOnClickListener { connect() }
        hzButton.setOnClickListener {
            hzIndex = (hzIndex + 1) % hzOptions.size
            hzButton.text = hzLabel()
            applyRefreshRate(hzOptions[hzIndex])
        }

        surfaceView.setOnTouchListener { _, event -> handleTouch(event) }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {}
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (streaming) applyRefreshRate(hzOptions[hzIndex])
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })

        applyRefreshRate(hzOptions[hzIndex])
        hideSystemUi()

        // `adb shell am start ... --ez autoconnect true` starts streaming
        // immediately with the address from the field.
        if (intent.getBooleanExtra("autoconnect", false)) {
            surfaceView.post { connect() }
        }
    }

    private fun hzLabel() = "Частота экрана: ${hzOptions[hzIndex]} Гц"

    private fun connect() {
        val addr = addressEdit.text.toString().trim().split(":")
        val host = addr.getOrNull(0) ?: return
        val port = addr.getOrNull(1)?.toIntOrNull() ?: 7381

        val display = display ?: return
        val real = Point()
        display.getRealSize(real)
        val refresh = refreshFor(hzOptions[hzIndex], display)

        statusText.text = "Подключение к $host:$port…"
        connection = DsxpConnection(host, port, this).also {
            it.connect(real.x, real.y, refresh)
        }
    }

    // ---------------- connection callbacks ----------------

    override fun onAck(config: JSONObject) {
        runOnUiThread {
            if (!config.optBoolean("ok")) {
                statusText.text = "Mac отказал: $config"
                return@runOnUiThread
            }
            pendingWidth = config.optInt("width", 2944)
            pendingHeight = config.optInt("height", 1840)
            val fps = config.optInt("fps", 120)
            statusText.text = "Поток: ${pendingWidth}×${pendingHeight} @ $fps fps"
            controls.visibility = View.GONE
            streaming = true
            hideSystemUi()
        }
    }

    override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {
        if (!streaming) return
        android.util.Log.d("DSXP", "frame ${annexB.size}B")
        var d = decoder
        if (d == null) {
            d = VideoDecoder(surfaceView.holder.surface, pendingWidth, pendingHeight)
            decoder = d
        }
        if (!d.started) {
            val key = d.isKeyframe(annexB)
            android.util.Log.d("DSXP", "waiting keyframe, isKey=$key")
            if (key) {
                if (!d.startFromKeyframe(annexB)) {
                    android.util.Log.e("DSXP", "decoder start failed: ${d.lastError}")
                    runOnUiThread {
                        statusText.text = "Ошибка декодера: ${d.lastError}"
                    }
                } else {
                    android.util.Log.d("DSXP", "decoder started")
                }
            }
            return
        }
        d.feed(annexB)
    }

    override fun onStats(stats: JSONObject) {}

    override fun onDisconnected(reason: String?) {
        runOnUiThread {
            streaming = false
            decoder?.stop()
            decoder = null
            controls.visibility = View.VISIBLE
            statusText.text = if (reason != null) "Отключено: $reason" else "Отключено"
        }
    }

    // ---------------- touch -> mac input ----------------

    private fun handleTouch(event: MotionEvent): Boolean {
        if (!streaming) return false
        val conn = connection ?: return false
        val w = surfaceView.width.toFloat()
        val h = surfaceView.height.toFloat()
        if (w <= 0 || h <= 0) return true

        fun send(vararg pairs: Pair<String, Any>) {
            val json = JSONObject()
            for ((k, v) in pairs) json.put(k, v)
            conn.sendInput(json)
        }

        val x = (event.x / w).coerceIn(0f, 1f).toDouble()
        val y = (event.y / h).coerceIn(0f, 1f).toDouble()

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount >= 2) {
                    twoFinger = true
                    if (touching) {
                        send("t" to "up", "x" to x, "y" to y)
                        touching = false
                    }
                    lastScroll.set(event)
                } else {
                    touching = true
                    send("t" to "down", "x" to x, "y" to y)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (twoFinger && event.pointerCount >= 2) {
                    val dx = event.x - lastScroll.x
                    val dy = event.y - lastScroll.y
                    if (abs(dx) > 4 || abs(dy) > 4) {
                        send("t" to "scroll", "dx" to (dx / 24).toDouble(), "dy" to (dy / 24).toDouble())
                        lastScroll.set(event)
                    }
                } else if (touching) {
                    send("t" to "drag", "x" to x, "y" to y)
                } else {
                    send("t" to "move", "x" to x, "y" to y)
                }
            }
            MotionEvent.ACTION_UP -> {
                if (touching) send("t" to "up", "x" to x, "y" to y)
                touching = false
                twoFinger = false
            }
            MotionEvent.ACTION_POINTER_UP -> {
                twoFinger = false
            }
            MotionEvent.ACTION_CANCEL -> {
                if (touching) send("t" to "up", "x" to x, "y" to y)
                touching = false
                twoFinger = false
            }
        }
        return true
    }

    // ---------------- refresh rate ----------------

    private fun refreshFor(targetHz: Int, display: Display): Int {
        val modes = display.supportedModes
        // prefer the mode matching target refresh and panel resolution
        val best = modes.filter { it.refreshRate >= targetHz - 2 && it.refreshRate <= targetHz + 20 }
            .minByOrNull { abs(it.refreshRate - targetHz) }
            ?: modes.maxByOrNull { it.refreshRate }
            ?: return targetHz
        return best.refreshRate.toInt()
    }

    private fun applyRefreshRate(targetHz: Int) {
        val display = display ?: return
        val modes = display.supportedModes
        val mode = modes
            .filter { abs(it.refreshRate - targetHz) < 20f && it.refreshRate <= targetHz + 1f }
            .maxByOrNull { it.refreshRate }
            ?: modes.maxByOrNull { it.refreshRate }
            ?: return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = mode.modeId
        }
    }

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            )
    }

    override fun onDestroy() {
        connection?.close()
        decoder?.stop()
        super.onDestroy()
    }
}

private class PointF0 {
    var x = 0f
    var y = 0f
    fun set(e: MotionEvent) { x = e.x; y = e.y }
}
