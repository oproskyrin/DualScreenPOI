package com.oleg.dualscreen

import android.annotation.SuppressLint
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Point
import android.media.AudioManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.view.*
import android.view.inputmethod.InputMethodManager
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import org.json.JSONObject
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

class MainActivity : AppCompatActivity() {
    private enum class State { IDLE, DISCOVERING, CONNECTING, STREAMING, RECONNECTING, ERROR }
    private val handler = Handler(Looper.getMainLooper())
    private val session = ConnectionSession()
    private var notificationOwner: Long? = null
    private var notificationServiceStarted = false
    private var activityVisible = false
    private var notificationExplanation: AlertDialog? = null
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) notificationUnavailable()
    }
    private val mediaLock = Any()
    private val prefs by lazy { getSharedPreferences("ds", MODE_PRIVATE) }
    private lateinit var ui: ClientUi
    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var cursorOverlay: CursorOverlayView
    private lateinit var home: View
    private lateinit var homeStatus: TextView
    private lateinit var wifiList: LinearLayout
    private lateinit var overlay: LinearLayout
    private lateinit var overlayText: TextView
    private lateinit var toolbar: LinearLayout
    private lateinit var toolbarHandle: Button
    private var toolbarExpanded = true
    private var handleX = 1f
    private var handleY = 0f
    private lateinit var statusText: TextView
    private lateinit var kbBuffer: EditText
    private var state = State.IDLE
    private var connection: DsxpConnection? = null
    @Volatile private var decoder: VideoDecoder? = null
    private val audioPlayer = AudioPlayer()
    @Volatile private var streaming = false
    @Volatile private var config = JSONObject()
    @Volatile private var lastHostStats: JSONObject? = null
    private var pendingWidth = 0
    private var pendingHeight = 0
    private var requestedHz = 120
    private var diagnostics = false
    private var audioEnabled = true
    private var localCursor = true

    private var keyboardVisible = false
    private var settingsDialog: AlertDialog? = null
    @Suppress("DEPRECATION")
    private val panelDisplay: Display get() = windowManager.defaultDisplay
    private var lastStatsSent = 0L
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val nsd by lazy { getSystemService(Context.NSD_SERVICE) as NsdManager }
    private var discoveryGeneration = 0L
    private val discovered = linkedMapOf<String, Pair<String, Endpoint>>()
    private val resolveQueue = java.util.ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val discoveryTimeout = Runnable {
        stopDiscovery()
        if (state == State.DISCOVERING) setState(State.IDLE,
            if (discovered.isEmpty()) "Mac не найден. Проверьте общую Wi-Fi сеть и запущенный DualScreen на Mac." else "Выберите Mac для подключения")
        renderDiscovered()
    }
    private val statsUpdater = object : Runnable {
        override fun run() {
            if (!streaming) return
            val d = decoder
            val latency = d?.latencyMs ?: 0.0
            val fps = d?.fps ?: 0.0
            if (diagnostics) statusText.text = String.format(Locale.getDefault(),
                "Декодер: %.0f мс · %.0f fps\nЗадано на Mac: %d fps · %d Мбит/с · Панель: %.0f Гц",
                latency, fps, config.optInt("fps", requestedHz), lastHostStats?.optInt("bitrateMbps", 0) ?: 0,
                panelDisplay.refreshRate)
            // ABR feedback is independent of whether diagnostics are visible.
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastStatsSent >= 2000) {
                lastStatsSent = now
                connection?.sendStats(JSONObject().put("latencyMs", latency).put("fps", fps))
            }
            updateSessionNotification()
            handler.postDelayed(this, 1000)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui = ClientUi(this)
        diagnostics = prefs.getBoolean("diagnostics", false)
        audioEnabled = prefs.getBoolean("audio_enabled", true)
        localCursor = prefs.getBoolean("local_cursor", true)
        requestedHz = prefs.getInt("requested_hz", 120)
        handleX = prefs.getFloat("toolbar_x", 1f)
        handleY = prefs.getFloat("toolbar_y", 0f)
        if (prefs.getBoolean("user_stopped", false)) session.cancel()
        volumeControlStream = AudioManager.STREAM_MUSIC
        root = FrameLayout(this).apply { setBackgroundColor(ui.background) }
        surfaceView = SurfaceView(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        // Draw-only local cursor: right above the video, below every control.
        cursorOverlay = CursorOverlayView(this).apply { setCursorEnabled(localCursor) }
        root.addView(cursorOverlay, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        buildHome()
        buildStreamControls()
        buildKeyboard()
        setContentView(root)
        surfaceView.setOnTouchListener { _, event -> handleTouch(event) }
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                applyRefreshRate(requestedHz)
                // A recreated surface needs a fresh keyframe even on a static Mac.
                if (streaming) connection?.requestReconnect()
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                synchronized(mediaLock) { decoder?.stop(); decoder = null }
            }
        })
        root.addOnLayoutChangeListener { _, l, t, r, b, oldL, oldT, oldR, oldB ->
            if (r-l != oldR-oldL || b-t != oldB-oldT) {
                relayoutStream(pendingWidth, pendingHeight)
                positionToolbar()
            }
        }
        setState(State.IDLE, "Mac + планшет. Больше места для ваших идей.")
        hideSystemUi()
        handleAutoconnect(intent)
    }

    private fun buildHome() {
        val page = ui.column(32)
        val heading = ui.row()
        val brand = ui.column()
        ui.label(brand, "DUALSCREEN  /  ДЛЯ MAC", 13f, ui.accent, true)
        ui.label(brand, "Ваш Mac. Ещё один экран.", 32f, bold = true)
        ui.label(brand, "Рабочее пространство без границ — по кабелю или Wi-Fi.", 16f, ui.muted)
        heading.addView(brand, LinearLayout.LayoutParams(0, -2, 1f))
        heading.addView(ui.button("Настройки") { showSettings() })
        page.addView(heading)
        homeStatus = ui.label(page, "", 15f, ui.accent)
        homeStatus.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        val cards = ui.row().apply { gravity = Gravity.TOP }
        val usb = ui.card()
        ui.label(usb, "01  /  КАБЕЛЬ", 12f, ui.accent, true)
        ui.label(usb, "USB", 30f, bold = true)
        ui.label(usb, "Стабильное соединение\nБез общей Wi-Fi сети", 17f, ui.muted)
        ui.addButton(usb, "Подключить по USB", true) { connectTo(Endpoint.USB, false) }
        ui.addButton(usb, "Как подключить USB") { showUsbHelp() }
        ui.label(usb, "Нужен USB-туннель от приложения на Mac. Один кабель без настройки ADB недостаточен.", 13f, ui.muted)
        val wifi = ui.card()
        ui.label(wifi, "02  /  БЕЗ ПРОВОДОВ", 12f, ui.accent, true)
        ui.label(wifi, "Wi-Fi", 30f, bold = true)
        ui.label(wifi, "Mac и планшет в одной сети.\nВы сами выбираете устройство.", 17f, ui.muted)
        ui.addButton(wifi, "Найти Mac по Wi-Fi", true) { discoverMac() }
        val saved = prefs.getString("wifi_addr", null)
            ?: prefs.getString("addr", null)?.takeUnless { it.startsWith("127.") || it.startsWith("localhost") }
        Endpoint.parse(saved ?: "")?.let { endpoint ->
            ui.addButton(wifi, "Последний Mac · ${endpoint.address}") { connectTo(endpoint, true) }
        }
        ui.addButton(wifi, "Ввести адрес вручную") { showManualAddress() }
        wifiList = ui.column()
        wifi.addView(wifiList)
        cards.addView(usb, LinearLayout.LayoutParams(0, -2, 1f).apply { rightMargin = ui.dp(10) })
        cards.addView(wifi, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = ui.dp(10) })
        page.addView(cards, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(12) })
        ui.label(page, "HEVC  ·  Сенсорное управление  ·  До 120 fps по умолчанию", 13f, ui.muted)
        home = ui.scroll(page)
        home.setBackgroundColor(ui.background)
        root.addView(home, FrameLayout.LayoutParams(-1, -1))
    }

    private fun buildStreamControls() {
        statusText = ui.text("", 12f, ui.ink).apply {
            background = ui.shape(0xD914202E.toInt(), 10)
            setPadding(ui.dp(12), ui.dp(8), ui.dp(12), ui.dp(8))
        }
        root.addView(statusText, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START).apply { leftMargin=ui.dp(16); bottomMargin=ui.dp(16) })
        toolbar = ui.row().apply { background = ui.shape(0xEE14202E.toInt(), 14); setPadding(ui.dp(6), ui.dp(6), ui.dp(6), ui.dp(6)) }
        listOf("Клавиатура" to { toggleKeyboard() }, "Настройки" to { showSettings() },
            "Отключиться" to { disconnectHome() }, "Скрыть панель" to { setToolbarVisible(false) }).forEach { (label, action) ->
            toolbar.addView(ui.button(label, action = action), LinearLayout.LayoutParams(-2, -2).apply { marginStart = ui.dp(4) })
        }
        root.addView(toolbar, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END).apply { topMargin=ui.dp(12); rightMargin=ui.dp(12) })
        toolbarHandle = ui.button("☰") { setToolbarVisible(true) }.apply {
            contentDescription = "Показать панель управления"
            minWidth = ui.dp(56); minimumWidth = ui.dp(56)
            // Only the background is translucent: fading the whole View also
            // fades the icon/border, making the control disappear on wallpaper.
            background = ui.shape(0xD914202E.toInt(), 16, 0xCCFFFFFF.toInt())
            setTextColor(android.graphics.Color.WHITE)
            textSize = 26f
            setPadding(0, 0, 0, 0)
            elevation = ui.dp(6).toFloat()
            alpha = 1f
        }
        root.addView(toolbarHandle, FrameLayout.LayoutParams(ui.dp(56), ui.dp(56), Gravity.TOP or Gravity.START))
        enableHandleDrag()
        overlay = ui.column(32).apply {
            gravity = Gravity.CENTER
            background = ui.shape(0xFA121C29.toInt(), 24)
            isClickable = true
        }
        overlay.addView(ProgressBar(this), LinearLayout.LayoutParams(ui.dp(40), ui.dp(40)))
        overlayText = ui.label(overlay, "Подключение…", 21f, bold = true).apply {
            gravity = Gravity.CENTER; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        ui.label(overlay, "Если связь прервалась, мы восстановим её автоматически.", 14f, ui.muted)
        ui.addButton(overlay, "Отменить подключение") { disconnectHome() }
        root.addView(overlay, FrameLayout.LayoutParams(ui.dp(480), -2, Gravity.CENTER))
    }

    private fun buildKeyboard() {
        kbBuffer = EditText(this).apply {
            alpha = 0f
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            addTextChangedListener(object : TextWatcher {
                private var before = ""
                private var clearing = false
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) { before = s?.toString().orEmpty() }
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    if (clearing || !streaming) return
                    val now = s?.toString().orEmpty()
                    if (now.length > before.length) sendKeyChar(now.substring(before.length))
                    else repeat(before.length - now.length) { sendKeySpecial("backspace") }
                    if (now.length > 128) { clearing = true; s?.clear(); clearing = false }
                }
            })
            setOnKeyListener { _, key, event ->
                if (event.action != KeyEvent.ACTION_DOWN || !streaming) false else when (key) {
                    KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> { sendKeySpecial("enter"); true }
                    KeyEvent.KEYCODE_DEL -> { sendKeySpecial("backspace"); true }
                    else -> false
                }
            }
        }
        root.addView(kbBuffer, FrameLayout.LayoutParams(1, 1, Gravity.BOTTOM or Gravity.START))
    }

    private fun setState(next: State, message: String = "") {
        state = next
        val busy = next == State.CONNECTING || next == State.RECONNECTING
        val live = next == State.STREAMING
        if (!live) cursorOverlay.hide()
        home.visibility = if (busy || live) View.GONE else View.VISIBLE
        overlay.visibility = if (busy) View.VISIBLE else View.GONE
        if (live) setToolbarVisible(toolbarExpanded) else {
            toolbar.visibility = View.GONE
            toolbarHandle.visibility = View.GONE
        }
        statusText.visibility = if (live && diagnostics) View.VISIBLE else View.GONE
        if (message.isNotEmpty()) { homeStatus.text = message; overlayText.text = message }
        if (busy || live) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        updateSessionNotification()
    }

    private fun setToolbarVisible(visible: Boolean) {
        toolbarExpanded = visible
        toolbar.visibility = if (visible) View.VISIBLE else View.GONE
        toolbarHandle.visibility = if (visible) View.GONE else View.VISIBLE
        root.post { positionToolbar() }
    }

    private fun handleBounds() = FloatingPanelPosition(root.width.toFloat(), root.height.toFloat(),
        ui.dp(56).toFloat(), ui.dp(56).toFloat(), ui.dp(12).toFloat())

    private fun positionToolbar() {
        if (root.width <= 0 || root.height <= 0) return
        val bounds = handleBounds()
        toolbarHandle.x = bounds.x(handleX)
        toolbarHandle.y = bounds.y(handleY)
        toolbar.post {
            val margin = ui.dp(12).toFloat()
            // Open next to the handle, clamped so every action stays reachable.
            val desiredX = toolbarHandle.x + ui.dp(28) - toolbar.width / 2f
            val desiredY = toolbarHandle.y
            toolbar.translationX = 0f; toolbar.translationY = 0f
            toolbar.x = desiredX.coerceIn(0f, (root.width - toolbar.width - margin).coerceAtLeast(0f))
            toolbar.y = desiredY.coerceIn(0f, (root.height - toolbar.height - margin).coerceAtLeast(0f))
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun enableHandleDrag() {
        var downX = 0f; var downY = 0f
        var startX = 0f; var startY = 0f
        var dragging = false
        val slop = ViewConfiguration.get(this).scaledTouchSlop
        toolbarHandle.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY
                    startX = view.x; startY = view.y; dragging = false
                    view.animate().cancel(); view.alpha = 1f
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX; val dy = event.rawY - downY
                    if (dx * dx + dy * dy > slop * slop) dragging = true
                    if (dragging) {
                        val bounds = handleBounds()
                        handleX = bounds.fractionX(startX + dx)
                        handleY = bounds.fractionY(startY + dy)
                        view.x = bounds.x(handleX); view.y = bounds.y(handleY)
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) prefs.edit().putFloat("toolbar_x", handleX).putFloat("toolbar_y", handleY).apply()
                    else if (event.actionMasked == MotionEvent.ACTION_UP) view.performClick()
                    view.alpha = 1f
                    true
                }
                else -> true
            }
        }
    }

    private fun handleAutoconnect(intent: Intent) {
        if (intent.action == SessionNotificationService.ACTION_OPEN) return
        if (!intent.getBooleanExtra("autoconnect", false) || !session.allowAutoconnect ||
            state in listOf(State.CONNECTING, State.STREAMING, State.RECONNECTING)) return
        val endpoint = Endpoint.parse(intent.getStringExtra("addr") ?: Endpoint.USB.address) ?: return
        surfaceView.post { if (session.allowAutoconnect && state == State.IDLE) connectTo(endpoint, endpoint != Endpoint.USB) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAutoconnect(intent)
    }

    private fun connectTo(endpoint: Endpoint, wifi: Boolean) {
        stopDiscovery()
        val token: Long
        synchronized(mediaLock) {
            token = session.begin()
            streaming = false
            connection?.close()
            decoder?.stop(); decoder = null
            audioPlayer.stop()
            config = JSONObject(); lastHostStats = null
        }
        prefs.edit().putBoolean("user_stopped", false).apply()
        val notification = SessionNotificationStatus(endpoint, wifi, SessionPhase.CONNECTING)
        notificationOwner = SessionNotificationService.sessions.begin(notification)
        setState(State.CONNECTING, "Подключение · ${if (wifi) endpoint.host else "USB"}")
        startSessionNotification()
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) offerSessionNotifications()
        val size = Point()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealSize(size)
        val listener = object : DsxpConnection.Listener {
            override fun onAck(config: JSONObject) {
                synchronized(mediaLock) {
                    if (!session.accepts(token)) return
                    if (!config.optBoolean("ok")) {
                        handler.post { if (session.accepts(token)) { disconnectHome(); setState(State.ERROR, "Mac отклонил подключение. Проверьте приложение на Mac.") } }
                        return
                    }
                    val w = config.optInt("width", 2944); val h = config.optInt("height", 1840)
                    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return
                    if (w != pendingWidth || h != pendingHeight) { decoder?.stop(); decoder = null }
                    pendingWidth = w; pendingHeight = h
                    this@MainActivity.config = config
                    streaming = true
                    if (audioEnabled && config.optString("audio").isNotEmpty()) runCatching { audioPlayer.start() }
                    else audioPlayer.stop()
                }
                handler.post {
                    if (!session.accepts(token)) return@post
                    relayoutStream(pendingWidth, pendingHeight)
                    if (wifi) prefs.edit().putString("wifi_addr", endpoint.address).apply()
                    setState(State.STREAMING)
                    if (settingsDialog?.isShowing == true) showSettings()
                    hideSystemUi()
                    handler.removeCallbacks(statsUpdater); handler.post(statsUpdater)
                }
            }
            override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {
                synchronized(mediaLock) {
                    if (!session.accepts(token) || !streaming || !surfaceView.holder.surface.isValid) return
                    val d = decoder ?: VideoDecoder(surfaceView.holder.surface, pendingWidth, pendingHeight).also { decoder = it }
                    if (!d.started) {
                        if (!d.isKeyframe(annexB)) return
                        if (!d.startFromKeyframe(annexB)) {
                            if (d.lastError != null) handler.post {
                                if (session.accepts(token)) { disconnectHome(); setState(State.ERROR, "Не удалось запустить HEVC-декодер. Попробуйте подключиться снова.") }
                            }
                            return
                        }
                    }
                    d.feed(annexB)
                }
            }
            override fun onAudio(pcm: ByteArray) { synchronized(mediaLock) { if (session.accepts(token) && streaming && audioEnabled) audioPlayer.feed(pcm) } }
            override fun onStats(stats: JSONObject) { if (session.accepts(token)) lastHostStats = stats }
            override fun onDisconnected(reason: String?) {
                synchronized(mediaLock) {
                    if (!session.accepts(token)) return
                    streaming = false; decoder?.stop(); decoder = null; audioPlayer.stop()
                }
                handler.post {
                    if (!session.accepts(token)) return@post
                    hideKeyboard()
                    handler.removeCallbacks(statsUpdater)
                    setState(State.RECONNECTING, "Восстанавливаем связь · ${if (wifi) endpoint.host else "USB"}\nПроверьте ${if (wifi) "Wi-Fi и приложение на Mac" else "кабель и USB-туннель на Mac"}")
                }
            }
        }
        connection = DsxpConnection(endpoint.host, endpoint.port, listener).also { it.connect(size.x, size.y, requestedHz) }
    }

    private fun updateSessionNotification() {
        val owner = notificationOwner ?: return
        val current = SessionNotificationService.sessions.current ?: return
        val phase = when (state) {
            State.CONNECTING -> SessionPhase.CONNECTING
            State.STREAMING -> SessionPhase.CONNECTED
            State.RECONNECTING -> SessionPhase.RECONNECTING
            else -> return
        }
        SessionNotificationService.sessions.update(owner, current.copy(
            phase = phase,
            mirror = if (config.has("mirror")) config.optBoolean("mirror") else null,
            configuredFps = if (config.has("fps")) config.optInt("fps") else null,
            decoderFps = decoder?.takeIf { it.started }?.fps
        ))
    }

    private fun startSessionNotification() {
        if (!activityVisible || notificationOwner == null || notificationServiceStarted) return
        try {
            ContextCompat.startForegroundService(this, Intent(this, SessionNotificationService::class.java))
            notificationServiceStarted = true
        } catch (e: RuntimeException) {
            android.util.Log.w("DualScreen", "Cannot start Mac session service", e)
            Toast.makeText(this, "Android не разрешил фоновое соединение. Оставьте DualScreen открытым.", Toast.LENGTH_LONG).show()
        }
    }

    private fun stopSessionNotification() {
        val owner = notificationOwner ?: return
        notificationOwner = null
        notificationServiceStarted = false
        if (SessionNotificationService.sessions.end(owner)) {
            stopService(Intent(this, SessionNotificationService::class.java))
        }
    }

    private fun notificationUnavailable() {
        Toast.makeText(this, "Уведомления выключены: возврат из шторки недоступен. Откройте DualScreen через недавние приложения. Соединение не остановлено.", Toast.LENGTH_LONG).show()
    }

    private fun offerSessionNotifications(explicit: Boolean = false) {
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) || notificationExplanation?.isShowing == true) return
        val channel = getSystemService(android.app.NotificationManager::class.java)
            .getNotificationChannel(SessionNotificationService.CHANNEL_ID)
        val allowed = NotificationManagerCompat.from(this).areNotificationsEnabled() &&
            channel?.importance != android.app.NotificationManager.IMPORTANCE_NONE
        if (allowed) {
            if (explicit) Toast.makeText(this, "Уведомление появляется, пока идёт соединение с Mac.", Toast.LENGTH_LONG).show()
            return
        }
        val prompted = prefs.getBoolean("notification_prompted", false)
        if (!explicit && prompted) return
        if (explicit && (prompted || Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)) {
            startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
            return
        }
        if (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            if (explicit) notificationUnavailable()
            return
        }
        prefs.edit().putBoolean("notification_prompted", true).apply()
        notificationExplanation = AlertDialog.Builder(this)
            .setTitle("Возврат к экрану Mac")
            .setMessage("Разрешите тихое уведомление: в нём видны соединение и частота кадров. Нажатие вернёт DualScreen из шторки без нового подключения. Без разрешения соединение работает, но вернуться можно только через недавние приложения.")
            .setPositiveButton("Разрешить") { _, _ -> notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }
            .setNegativeButton("Не сейчас") { _, _ -> notificationUnavailable() }
            .setOnDismissListener { notificationExplanation = null }
            .show()
    }

    private fun disconnectHome() {
        stopSessionNotification()
        synchronized(mediaLock) {
            session.cancel(); streaming = false
            connection?.close(); connection = null
            decoder?.stop(); decoder = null; audioPlayer.stop()
        }
        prefs.edit().putBoolean("user_stopped", true).apply()
        handler.removeCallbacks(statsUpdater)
        stopDiscovery(); hideKeyboard()
        // Refresh the last-used card after a successful Wi-Fi session.
        root.removeView(home); buildHome(); home.bringToFront()
        setState(State.IDLE, "Соединение остановлено. Выберите способ подключения.")
    }

    private fun showUsbHelp() {
        AlertDialog.Builder(this).setTitle("Подключение по USB")
            .setMessage("1. Запустите DualScreen на Mac.\n\n2. Соедините устройства кабелем с передачей данных. На планшете включите режим разработчика и отладку по USB. Разрешите отладку для этого Mac.\n\n3. USB-подключение на Mac должно создать ADB-туннель: adb reverse tcp:7381 tcp:7381. Без него адрес 127.0.0.1 не ведёт к Mac.\n\n4. Нажмите «Подключить по USB». Если связь не установлена, проверьте кабель, разрешение отладки и туннель на Mac.")
            .setPositiveButton("Понятно", null).show()
    }

    private fun showManualAddress() {
        val input = EditText(this).apply {
            hint = "mac.local:7381 или 192.168.1.10:7381"
            setText(prefs.getString("wifi_addr", "")); setSingleLine()
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            setPadding(ui.dp(24), ui.dp(16), ui.dp(24), ui.dp(16))
            contentDescription = "Адрес Mac"
        }
        val dialog = AlertDialog.Builder(this).setTitle("Адрес Mac в Wi-Fi сети").setView(input)
            .setNegativeButton("Отмена", null).setPositiveButton("Подключить", null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val endpoint = Endpoint.parse(input.text.toString())
            if (endpoint == null || endpoint == Endpoint.USB) input.error = "Введите адрес Mac и порт 1–65535. Для кабеля используйте USB."
            else { dialog.dismiss(); connectTo(endpoint, true) }
        } }
        dialog.show()
    }

    @Suppress("DEPRECATION")
    private fun discoverMac() {
        stopDiscovery()
        discovered.clear(); renderDiscovered()
        val generation = discoveryGeneration
        setState(State.DISCOVERING, "Ищем Mac в общей сети… Выберите устройство из списка.")
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { handler.post {
                if (generation == discoveryGeneration) { stopDiscovery(); setState(State.ERROR, "Не удалось начать поиск ($code). Можно ввести адрес вручную.") }
            } }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { handler.post {
                if (generation == discoveryGeneration && state == State.DISCOVERING) { resolveQueue.add(info); resolveNext(generation) }
            } }
            override fun onServiceLost(info: NsdServiceInfo) { handler.post {
                if (generation == discoveryGeneration) { discovered.remove(info.serviceName); renderDiscovered() }
            } }
        }
        discoveryListener = listener
        renderDiscovered()
        runCatching { nsd.discoverServices("_dualscreen._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }.onFailure {
            stopDiscovery(); setState(State.ERROR, "Поиск недоступен. Введите адрес Mac вручную.")
        }
        handler.postDelayed(discoveryTimeout, 12000)
    }

    @Suppress("DEPRECATION")
    private fun resolveNext(generation: Long) {
        if (resolving || resolveQueue.isEmpty() || generation != discoveryGeneration) return
        resolving = true
        val info = resolveQueue.removeFirst()
        fun completed(found: NsdServiceInfo?) { handler.post {
            if (generation != discoveryGeneration) return@post
            resolving = false
            found?.host?.hostAddress?.let { host ->
                if (found.port in 1..65535) discovered[found.serviceName] = found.serviceName to Endpoint(host, found.port)
            }
            renderDiscovered(); resolveNext(generation)
        } }
        runCatching { nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) { completed(null) }
            override fun onServiceResolved(info: NsdServiceInfo) { completed(info) }
        }) }.onFailure { completed(null) }
    }

    private fun renderDiscovered() {
        wifiList.removeAllViews()
        discovered.values.forEach { (name, endpoint) ->
            ui.addButton(wifiList, "$name · ${endpoint.address}") { connectTo(endpoint, true) }
        }
        if (state == State.DISCOVERING) ui.addButton(wifiList, "Остановить поиск") {
            stopDiscovery(); setState(State.IDLE, "Поиск остановлен. Выберите Mac или введите адрес."); renderDiscovered()
        }
    }

    private fun stopDiscovery() {
        discoveryGeneration++
        handler.removeCallbacks(discoveryTimeout)
        discoveryListener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discoveryListener = null; resolveQueue.clear(); resolving = false
    }

    private fun showSettings() {
        settingsDialog?.dismiss()
        val panel = ui.column(24)
        ui.addButton(panel, "Уведомление о соединении") { offerSessionNotifications(explicit = true) }
        val mirror = if (config.has("mirror")) config.optBoolean("mirror") else lastHostStats?.optString("mode") == "mirror"
        val mode = if (mirror) "Зеркало" else "Расширение"
        val connected = streaming
        ui.label(panel, "ЭКРАН MAC", 12f, ui.accent, true)
        ui.addButton(panel, "Режим · $mode") {
            choose("Режим Mac", arrayOf("Расширение", "Зеркало"), if (mode == "Зеркало") 1 else 0) { index ->
                connection?.sendCommand(JSONObject().put("cmd", "setMode").put("mode", if (index == 0) "extend" else "mirror"))
            }
        }.isEnabled = connected
        val lw = config.optInt("logicalW", config.optInt("width", 0))
        val lh = config.optInt("logicalH", config.optInt("height", 0))
        ui.addButton(panel, "Логическое разрешение · ${if (lw > 0) "$lw × $lh" else "по данным Mac"}") {
            val sizes = arrayOf(1472 to 920, 1920 to 1200, 2944 to 1840)
            choose("Логическое разрешение", arrayOf("1472 × 920 · Retina", "1920 × 1200", "2944 × 1840 · 1:1"), sizes.indexOf(lw to lh)) { index ->
                connection?.sendCommand(JSONObject().put("cmd", "setLogical").put("w", sizes[index].first).put("h", sizes[index].second))
            }
        }.isEnabled = connected
        if (!connected) ui.label(panel, "Режим и разрешение доступны после подключения.", 13f, ui.muted)
        ui.label(panel, "ЧАСТОТА", 12f, ui.accent, true)
        ui.addButton(panel, "Запрошено · $requestedHz Гц / fps") {
            val current = panelDisplay.mode
            val options = panelDisplay.supportedModes.filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .map { it.refreshRate.roundToInt() }.distinct().sorted().toIntArray()
            choose("Частота панели и потока", options.map { "$it Гц / fps" }.toTypedArray(), options.indexOf(requestedHz)) { index ->
                requestedHz = options[index]; prefs.edit().putInt("requested_hz", requestedHz).apply()
                applyRefreshRate(requestedHz)
                connection?.sendCommand(JSONObject().put("cmd", "setFps").put("fps", requestedHz))
                showSettings()
            }
        }
        ui.label(panel, "Панель сейчас: ${panelDisplay.refreshRate.roundToInt()} Гц. На Mac задано: ${if (connected) config.optInt("fps", 120).toString() else "—"} fps. Декодер фактически: ${if (connected) (decoder?.fps ?: 0.0).roundToInt().toString() else "—"} fps. Android может ограничивать частоту.", 13f, ui.muted)
        ui.label(panel, "ЗВУК НА ПЛАНШЕТЕ", 12f, ui.accent, true)
        panel.addView(Switch(this).apply {
            text = "Воспроизводить звук"; setTextColor(ui.ink); isChecked = audioEnabled
            contentDescription = "Воспроизводить звук"; minHeight = ui.dp(48)
            setOnCheckedChangeListener { _, enabled ->
                audioEnabled = enabled; prefs.edit().putBoolean("audio_enabled", enabled).apply()
                synchronized(mediaLock) {
                    if (!enabled) audioPlayer.stop()
                    else if (streaming && config.optString("audio").isNotEmpty()) runCatching { audioPlayer.start() }
                }
            }
        })
        ui.label(panel, "Источник выбирается на Mac. Этот переключатель только отключает звук на планшете.", 13f, ui.muted)
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        panel.addView(SeekBar(this).apply {
            contentDescription = "Громкость планшета"; max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            progress = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) { if (fromUser) audio.setStreamVolume(AudioManager.STREAM_MUSIC, value, 0) }
                override fun onStartTrackingTouch(bar: SeekBar?) {}
                override fun onStopTrackingTouch(bar: SeekBar?) {}
            })
        })
        ui.label(panel, "ДИАГНОСТИКА", 12f, ui.accent, true)
        panel.addView(Switch(this).apply {
            text = "Показывать статистику"; setTextColor(ui.ink); isChecked = diagnostics; minHeight = ui.dp(48)
            contentDescription = "Показывать статистику"
            setOnCheckedChangeListener { _, enabled ->
                diagnostics = enabled; prefs.edit().putBoolean("diagnostics", enabled).apply()
                statusText.visibility = if (enabled && streaming) View.VISIBLE else View.GONE
            }
        })
        ui.label(panel, "Задержка — от подачи кадра в декодер до его выдачи, не задержка Mac → планшет. Обратная связь для адаптивного битрейта работает всегда.", 13f, ui.muted)
        panel.addView(Switch(this).apply {
            text = "Локальный курсор"; setTextColor(ui.ink); isChecked = localCursor; minHeight = ui.dp(48)
            contentDescription = "Локальный курсор"
            setOnCheckedChangeListener { _, enabled ->
                localCursor = enabled
                prefs.edit().putBoolean("local_cursor", enabled).apply()
                cursorOverlay.setCursorEnabled(enabled)
            }
        })
        ui.label(panel, "Рисует указатель на планшете сразу под пальцем, пока изображение с Mac догоняет. На сам ввод не влияет.", 13f, ui.muted)
        settingsDialog = AlertDialog.Builder(this).setTitle("Настройки DualScreen").setView(ui.scroll(panel)).setPositiveButton("Готово", null).show()
    }

    private fun choose(title: String, options: Array<String>, current: Int, selected: (Int) -> Unit) {
        AlertDialog.Builder(this).setTitle(title).setSingleChoiceItems(options, current) { dialog, index -> selected(index); dialog.dismiss() }
            .setNegativeButton("Отмена", null).show()
    }

    private fun sendKeyChar(value: String) { if (streaming) connection?.sendInput(JSONObject().put("t", "key").put("ch", value)) }
    private fun sendKeySpecial(value: String) { if (streaming) connection?.sendInput(JSONObject().put("t", "key").put("special", value)) }
    private fun toggleKeyboard() {
        if (keyboardVisible) { hideKeyboard(); return }
        keyboardVisible = true; kbBuffer.requestFocus()
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(kbBuffer, InputMethodManager.SHOW_IMPLICIT)
    }
    private fun hideKeyboard() {
        keyboardVisible = false
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(kbBuffer.windowToken, 0)
        kbBuffer.clearFocus()
    }

    private fun relayoutStream(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        root.post {
            if (root.width <= 0 || root.height <= 0) return@post
            val scale = minOf(root.width.toFloat()/w, root.height.toFloat()/h)
            val width = (w*scale).toInt(); val height = (h*scale).toInt()
            if (surfaceView.width != width || surfaceView.height != height) surfaceView.layoutParams = FrameLayout.LayoutParams(width, height, Gravity.CENTER)
        }
    }

    private fun applyRefreshRate(target: Int) {
        val display = panelDisplay
        val mode = display.supportedModes.filter { it.physicalWidth == display.mode.physicalWidth && it.physicalHeight == display.mode.physicalHeight }
            .minByOrNull { abs(it.refreshRate-target) } ?: return
        window.attributes = window.attributes.apply { preferredDisplayModeId = mode.modeId; preferredRefreshRate = mode.refreshRate }
    }

    override fun onConfigurationChanged(newConfig: Configuration) { super.onConfigurationChanged(newConfig); relayoutStream(pendingWidth, pendingHeight) }
    override fun onStart() {
        super.onStart()
        activityVisible = true
        startSessionNotification()
    }
    override fun onResume() {
        super.onResume()
        // Lifecycle reaches RESUMED after this callback returns.
        handler.post { if (notificationOwner != null) offerSessionNotifications() }
    }
    override fun onStop() {
        activityVisible = false
        stopDiscovery()
        if (state == State.DISCOVERING) { setState(State.IDLE, "Поиск приостановлен. Нажмите «Найти Mac по Wi-Fi»."); renderDiscovered() }
        super.onStop()
    }
    @Deprecated("Native back handling retained for API 26")
    override fun onBackPressed() {
        if (keyboardVisible) hideKeyboard()
        else if (state in listOf(State.CONNECTING, State.RECONNECTING, State.STREAMING)) disconnectHome()
        else if (state == State.DISCOVERING) { stopDiscovery(); setState(State.IDLE, "Поиск остановлен"); renderDiscovered() }
        else super.onBackPressed()
    }
    private fun hideSystemUi() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
    }
    override fun onDestroy() {
        notificationExplanation?.dismiss()
        stopSessionNotification()
        session.cancel(); stopDiscovery(); handler.removeCallbacksAndMessages(null)
        synchronized(mediaLock) { streaming = false; connection?.close(); decoder?.stop(); decoder = null; audioPlayer.stop() }
        super.onDestroy()
    }

    // Touch gestures are retained from the existing client.
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

        // Local cursor follows the primary pointer in root coordinates (the
        // overlay spans the root while event coords are surfaceView-relative).
        val cursorX = surfaceView.left + event.getX(0)
        val cursorY = surfaceView.top + event.getY(0)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touching = true
                movedFar = false
                downAt = System.currentTimeMillis()
                downX = event.x; downY = event.y
                cursorOverlay.show(cursorX, cursorY)
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
                cursorOverlay.move(cursorX, cursorY)
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
                cursorOverlay.hide()
            }
            MotionEvent.ACTION_CANCEL -> {
                if (touching) send("t" to "up", "x" to x, "y" to y)
                touching = false
                twoFinger = false
                cursorOverlay.hide()
            }
        }
        return true
    }


}

private class PointF0 {
    var x = 0f
    var y = 0f
    fun set(e: MotionEvent) { x = e.x; y = e.y }
}
