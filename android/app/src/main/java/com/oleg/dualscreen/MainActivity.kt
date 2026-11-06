package com.oleg.dualscreen

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Point
import android.graphics.Typeface
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
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
    private lateinit var keyboardButton: Button
    private lateinit var settingsButton: Button
    private lateinit var kbBuffer: EditText

    private var connection: DsxpConnection? = null
    private var decoder: VideoDecoder? = null
    private val audioPlayer = AudioPlayer()
    private var config = JSONObject()
    private var streaming = false
    private var everConnected = false
    private val statsHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var lastStatsSent = 0L
    private val statsUpdater = object : Runnable {
        override fun run() {
            if (streaming) {
                val d = decoder
                val lat = d?.latencyMs ?: 0.0
                val fps = d?.fps ?: 0.0
                val hostFps = lastHostStats?.optDouble("hostFps", 0.0) ?: 0.0
                val mode = lastHostStats?.optString("mode") ?: config.optString("mirror").let { if (it == "true") "mirror" else "extend" }
                val br = lastHostStats?.optInt("bitrateMbps", 0) ?: 0
                statusText.text = String.format(
                    "%s • %.0f мс • %.0f fps • %d Мбит/с",
                    if (mode == "mirror") "зеркало" else "расширение", lat, fps, br)
                // feed the Mac's adaptive bitrate controller (every ~2s)
                val now = System.currentTimeMillis()
                if (now - lastStatsSent >= 2000) {
                    lastStatsSent = now
                    connection?.sendStats(
                        JSONObject().put("latencyMs", lat).put("fps", fps))
                }
                statsHandler.postDelayed(this, 1000)
            }
        }
    }

    // default 120: matches the 120fps stream 1:1 (ZUI caps the panel at
    // 120Hz anyway; 144 causes judder without benefit)
    private val hzOptions = intArrayOf(120, 144, 90, 60)
    private var hzIndex = 0
    private var pendingWidth = 0
    private var pendingHeight = 0

    // touch state
    private var touching = false
    private var twoFinger = false
    private var lastScroll = PointF0()
    private var downAt = 0L
    private var downX = 0f
    private var downY = 0f
    private var movedFar = false
    private var twoFingerAt = 0L
    private var twoFingerMoved = false

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val root = FrameLayout(this)
        surfaceView = SurfaceView(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // --- startup controls ---
        controls = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        addressEdit = EditText(this).apply {
            hint = "host:port (127.0.0.1:7381 по USB)"
            setText(getSharedPreferences("ds", MODE_PRIVATE).getString("addr", "127.0.0.1:7381"))
        }
        val connectButton = Button(this).apply { text = "Подключить" }
        val findButton = Button(this).apply {
            text = "Найти Mac (Wi-Fi)"
            setOnClickListener { discoverMac() }
        }
        hzButton = Button(this).apply { text = hzLabel() }
        controls.addView(addressEdit)
        controls.addView(connectButton)
        controls.addView(findButton)
        controls.addView(hzButton)
        val pad = (resources.displayMetrics.density * 16).toInt()
        controls.setPadding(pad, pad * 2, pad, pad)
        root.addView(controls, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        // --- streaming overlays ---
        statusText = TextView(this).apply {
            text = "DualScreen"
            setTextColor(0xCCFFFFFF.toInt())
            textSize = 13f
            typeface = Typeface.MONOSPACE
        }
        root.addView(statusText, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START).apply {
            leftMargin = pad; topMargin = pad / 2
        })

        keyboardButton = Button(this).apply {
            text = "⌨"
            alpha = 0.35f
            setOnClickListener { toggleKeyboard() }
        }
        settingsButton = Button(this).apply {
            text = "⚙"
            alpha = 0.35f
            setOnClickListener { showSettings() }
        }
        val topButtons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        topButtons.addView(keyboardButton)
        topButtons.addView(settingsButton)
        root.addView(topButtons, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.END).apply {
            rightMargin = pad; topMargin = 0
        })

        // invisible input that captures the soft keyboard
        kbBuffer = EditText(this).apply {
            alpha = 0f
            layoutParams = FrameLayout.LayoutParams(1, 1, Gravity.BOTTOM or Gravity.START)
            addTextChangedListener(object : TextWatcher {
                var before = ""
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { before = s?.toString() ?: "" }
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    val now = s?.toString() ?: return
                    if (now.length > before.length) {
                        val added = now.substring(before.length)
                        if (added.isNotEmpty()) sendKeyChar(added)
                    } else if (now.length < before.length) {
                        repeat(before.length - now.length) { sendKeySpecial("backspace") }
                    }
                    if (now.length > 4) s?.delete(0, now.length - 4)
                }
            })
            setOnKeyListener { _, keyCode, event ->
                if (event.action == KeyEvent.ACTION_DOWN) {
                    when (keyCode) {
                        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> { sendKeySpecial("enter"); true }
                        KeyEvent.KEYCODE_DEL -> { sendKeySpecial("backspace"); true }
                        else -> false
                    }
                } else false
            }
        }
        root.addView(kbBuffer)

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

        // `adb shell am start ... --ez autoconnect true --es addr host:port`
        // starts streaming immediately with the address from the intent
        // (the USB autopilot passes 127.0.0.1 so a stale Wi-Fi IP never
        // blocks a wired connection).
        val addrExtra = intent.getStringExtra("addr")
        if (!addrExtra.isNullOrEmpty()) {
            addressEdit.setText(addrExtra)
            getSharedPreferences("ds", MODE_PRIVATE).edit()
                .putString("addr", addrExtra).apply()
        }
        if (intent.getBooleanExtra("autoconnect", false)) {
            surfaceView.post { connect() }
        }
    }

    // ---------------- aspect-correct stream layout (letterbox) ----------------

    /** Fits the SurfaceView to the stream's aspect ratio, centered. */
    private fun relayoutStream(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        val root = surfaceView.parent as? FrameLayout ?: return
        root.post {
            val rw = root.width.toFloat()
            val rh = root.height.toFloat()
            if (rw <= 0 || rh <= 0) return@post
            val scale = minOf(rw / w, rh / h)
            val lp = surfaceView.layoutParams as FrameLayout.LayoutParams
            lp.width = (w * scale).toInt()
            lp.height = (h * scale).toInt()
            lp.gravity = Gravity.CENTER
            surfaceView.layoutParams = lp
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // autopilot relaunch while we're the running instance: if the
        // connection died while backgrounded, reconnect now
        if (intent.hasExtra("addr")) {
            intent.getStringExtra("addr")?.let { addressEdit.setText(it) }
        }
        if (intent.getBooleanExtra("autoconnect", false) && !streaming) {
            surfaceView.post { connect() }
        }
    }

    private fun hzLabel() = "Частота экрана: ${hzOptions[hzIndex]} Гц"

    // ---------------- mDNS discovery ----------------

    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var nsdManager: NsdManager? = null

    @SuppressLint("SetTextI18n")
    private fun discoverMac() {
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = nsd
        statusText.text = "ищу Mac в сети…"

        fun stopDiscovery() {
            discoveryListener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
            discoveryListener = null
        }
        stopDiscovery()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                runOnUiThread { statusText.text = "mDNS не запущен (код $errorCode)" }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!serviceInfo.serviceType.contains("dualscreen")) return
                runOnUiThread { statusText.text = "нашёл ${serviceInfo.serviceName}, подключаюсь…" }
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        runOnUiThread { statusText.text = "не разрешился сервис ($errorCode)" }
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val host = info.host?.hostAddress ?: return
                        val p = info.port
                        runOnUiThread {
                            stopDiscovery()
                            addressEdit.setText("$host:$p")
                            connect()
                        }
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
        }
        discoveryListener = listener
        runCatching { nsd.discoverServices("_dualscreen._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun connect() {
        val addr = addressEdit.text.toString().trim().split(":")
        val host = addr.getOrNull(0) ?: return
        val port = addr.getOrNull(1)?.toIntOrNull() ?: 7381
        getSharedPreferences("ds", MODE_PRIVATE).edit()
            .putString("addr", "$host:$port").apply()

        val display = display ?: return
        val real = Point()
        display.getRealSize(real)
        val refresh = refreshFor(hzOptions[hzIndex], display)

        everConnected = false
        statusText.text = "подключение к $host:$port…"
        connection?.close()
        connection = DsxpConnection(host, port, this).also {
            it.connect(real.x, real.y, refresh)
        }
    }

    private fun sendKeyChar(ch: String) {
        connection?.sendInput(JSONObject().put("t", "key").put("ch", ch))
    }

    private fun sendKeySpecial(name: String) {
        connection?.sendInput(JSONObject().put("t", "key").put("special", name))
    }

    private fun toggleKeyboard() {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        kbBuffer.requestFocus()
        imm.showSoftInput(kbBuffer, InputMethodManager.SHOW_IMPLICIT)
        keyboardButton.alpha = if (keyboardButton.alpha < 0.9f) 0.9f else 0.35f
    }

    // ---------------- connection callbacks ----------------

    override fun onAck(config: JSONObject) {
        runOnUiThread {
            try {
                onAckUi(config)
            } catch (e: Exception) {
                android.util.Log.e("DSXP", "onAck UI failed", e)
            }
        }
    }

    private fun onAckUi(config: JSONObject) {
            if (!config.optBoolean("ok")) {
                statusText.text = "Mac отказал: $config"
                return
            }
            // resolution changed (mode switch on the host): restart the decoder
            // from the next keyframe instead of trusting adaptive decode
            val newW = config.optInt("width", 2944)
            val newH = config.optInt("height", 1840)
            if (this.config.optInt("width", newW) != newW ||
                this.config.optInt("height", newH) != newH) {
                decoder?.stop()
                decoder = null
            }
            this.config = config
            pendingWidth = newW
            pendingHeight = newH
            relayoutStream(newW, newH)
            val fps = config.optInt("fps", 120)
            everConnected = true
            streaming = true
            controls.visibility = View.GONE
            if (config.optString("audio").isNotEmpty()) audioPlayer.start()
            hideSystemUi()
            statsHandler.removeCallbacks(statsUpdater)
            statsHandler.post(statsUpdater)
    }

    override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {
        if (!streaming) return
        var d = decoder
        if (d == null) {
            d = VideoDecoder(surfaceView.holder.surface, pendingWidth, pendingHeight)
            decoder = d
        }
        if (!d.started) {
            if (d.isKeyframe(annexB)) {
                if (!d.startFromKeyframe(annexB)) {
                    runOnUiThread {
                        statusText.text = "ошибка декодера: ${d.lastError}"
                    }
                }
            }
            return
        }
        d.feed(annexB)
    }

    override fun onStats(stats: JSONObject) {
        lastHostStats = stats
    }

    override fun onAudio(pcm: ByteArray) {
        audioPlayer.feed(pcm)
    }

    // ---------------- remote settings panel ----------------

    private var lastHostStats: JSONObject? = null

    private fun showSettings() {
        val modes = arrayOf("Расширение (второй экран)", "Зеркало (повтор экрана)")
        val logicals = arrayOf("1472×920 Retina ⭐ (крупно и резко)", "1920×1200 (мельче)", "2944×1840 (1:1, очень мелко)")
        val logicalVals = arrayOf("1472x920", "1920x1200", "2944x1840")
        val conn = connection

        android.app.AlertDialog.Builder(this)
            .setTitle("Настройки Mac-хоста")
            .setSingleChoiceItems(modes + logicals, -1) { dialog, which ->
                val json = JSONObject()
                when {
                    which < modes.size -> json.put("cmd", "setMode")
                        .put("mode", if (which == 0) "extend" else "mirror")
                    else -> {
                        val v = logicalVals[which - modes.size].split("x")
                        json.put("cmd", "setLogical").put("w", v[0].toInt()).put("h", v[1].toInt())
                    }
                }
                conn?.sendCommand(json)
                dialog.dismiss()
            }
            .setNegativeButton("Закрыть", null)
            .show()
    }

    override fun onDisconnected(reason: String?) {
        runOnUiThread {
            if (everConnected) {
                // keep streaming UI; the connection retries automatically
                statusText.text = reason ?: "переподключение…"
                decoder?.stop()
                decoder = null
            } else {
                statusText.text = reason?.let { "нет связи: $it" } ?: "нет связи"
            }
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
            MotionEvent.ACTION_DOWN -> {
                touching = true
                movedFar = false
                downAt = System.currentTimeMillis()
                downX = event.x; downY = event.y
                send("t" to "down", "x" to x, "y" to y)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount == 2) {
                    twoFinger = true
                    twoFingerAt = System.currentTimeMillis()
                    twoFingerMoved = false
                    if (touching) {
                        send("t" to "up", "x" to x, "y" to y)
                        touching = false
                    }
                    lastScroll.set(event)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (abs(event.x - downX) > 18 || abs(event.y - downY) > 18) movedFar = true
                if (twoFinger && event.pointerCount >= 2) {
                    val dx = event.x - lastScroll.x
                    val dy = event.y - lastScroll.y
                    if (abs(dx) > 4 || abs(dy) > 4) {
                        twoFingerMoved = true
                        send("t" to "scroll", "dx" to (dx / 24).toDouble(), "dy" to (dy / 24).toDouble())
                        lastScroll.set(event)
                    }
                } else if (touching) {
                    send("t" to "drag", "x" to x, "y" to y)
                } else {
                    send("t" to "move", "x" to x, "y" to y)
                }
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // two-finger tap (no scroll, quick) = right click
                if (twoFinger && !twoFingerMoved &&
                    System.currentTimeMillis() - twoFingerAt < 300) {
                    send("t" to "right", "x" to x, "y" to y)
                }
                twoFinger = false
            }
            MotionEvent.ACTION_UP -> {
                if (touching) {
                    val held = System.currentTimeMillis() - downAt
                    if (!movedFar && held > 550) {
                        // long press = right click
                        send("t" to "up", "x" to x, "y" to y)
                        send("t" to "right", "x" to x, "y" to y)
                    } else {
                        send("t" to "up", "x" to x, "y" to y)
                    }
                }
                touching = false
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
        statsHandler.removeCallbacks(statsUpdater)
        connection?.close()
        decoder?.stop()
        audioPlayer.stop()
        super.onDestroy()
    }
}

private class PointF0 {
    var x = 0f
    var y = 0f
    fun set(e: MotionEvent) { x = e.x; y = e.y }
}
