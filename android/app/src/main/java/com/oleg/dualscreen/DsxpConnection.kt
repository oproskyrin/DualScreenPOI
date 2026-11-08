package com.oleg.dualscreen

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * DSXP v1 client: length-prefixed frames over TCP.
 * [u8 type][u32 BE length][payload]
 */
class DsxpConnection(
    private val host: String,
    private val port: Int,
    private val listener: Listener,
    private val diagnostics: (String) -> Unit = {},
    private val latency: LatencyTracker? = null,
    private val socketFactory: () -> Socket = { Socket() },
    private val supportedCodecs: (Int, Int) -> Set<VideoCodec> = { _, _ -> setOf(VideoCodec.HEVC) },
    private val preferredCodec: () -> VideoCodec = { VideoCodec.HEVC },
    private val clipboardEnabled: () -> Boolean = { true },
    private val micEnabled: () -> Boolean = { false }
) {
    interface Listener {
        fun onAck(config: JSONObject)
        fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean)
        fun onAudio(pcm: ByteArray) {}
        fun onStats(stats: JSONObject)
        fun onDisconnected(reason: String?)
        /** Incoming 0x06 clipboard text; called on the network thread. */
        fun onClipboard(text: String, hash: String) {}
        /** Terminal handshake error: do not retry an unsupported decoder forever. */
        fun onRejected(reason: String) { onDisconnected(reason) }
        /** Typed presentation error; legacy listeners still receive exact diagnostic metadata. */
        fun onRejected(error: CodecNegotiation.Rejected) { onRejected(error.message.orEmpty()) }
    }

    @Volatile private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    @Volatile private var networkThread: Thread? = null
    private val lifecycleLock = Any()
    private val running = AtomicBoolean(false)
    @Volatile private var userClosed = false
    private val sendLock = Any()
    // network writes must never happen on the main thread
    // (NetworkOnMainThreadException) — touch handlers and the stats overlay
    // both call send* from the UI thread
    private val sendExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val sessionId = nextSession.incrementAndGet()
    @Volatile private var attempt = 0L
    @Volatile private var attemptStarted = 0L
    @Volatile private var disconnectReason = "EOF"
    // Mic 0x07 in-flight count: incremented on the caller thread, decremented
    // after the executor task wrote the frame (or dropped the enqueue). When
    // full, frames are refused so the capture loop drops instead of letting
    // the send queue — and with it audio latency — grow without bound.
    private val micBacklog = java.util.concurrent.atomic.AtomicInteger()
    @Volatile private var micDropLogged = false
    private fun log(event: String) {
        runCatching { diagnostics("session=$sessionId attempt=$attempt $event") }
    }
    companion object {
        private val nextSession = java.util.concurrent.atomic.AtomicLong()
        /** Mic backlog ceiling: 4 × 20 ms frames = 80 ms of queued audio max. */
        const val MIC_MAX_BACKLOG_FRAMES = 4
    }

    fun connect(width: Int, height: Int, maxRefresh: Int) {
        synchronized(lifecycleLock) {
        if (userClosed || !running.compareAndSet(false, true)) return
        networkThread = Thread({
            var backoffMs = 1000L
            while (running.get() && !userClosed) {
                val ok = connectOnce(width, height, maxRefresh)
                if (ok) {
                    backoffMs = 1000L // reset after a successful session
                }
                if (running.get() && !userClosed) {
                    log("retry backoffMs=$backoffMs")
                    listener.onDisconnected(disconnectReason)
                    try { Thread.sleep(backoffMs) } catch (_: InterruptedException) {}
                    backoffMs = (backoffMs * 2).coerceAtMost(5000L)
                }
            }
        }, "dsxp-net").also { it.start() }
        }
    }

    /** One connection attempt + read loop. Returns true if a session was established. */
    private fun connectOnce(width: Int, height: Int, maxRefresh: Int): Boolean {
        var established = false
        attempt++
        attemptStarted = System.nanoTime()
        disconnectReason = "EOF"
        log("connect-attempt")
        try {
            val s = socketFactory()
            synchronized(lifecycleLock) {
                if (userClosed || !running.get()) { s.close(); return false }
                // Publish before blocking connect so cancellation closes it.
                socket = s
            }
            s.tcpNoDelay = true
            s.keepAlive = true
            // Host stats arrive every two seconds even on a static desktop.
            s.soTimeout = 8000
            s.receiveBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, port), 4000)
            if (userClosed || !running.get()) return false
            established = true
            log("connected durationMs=${(System.nanoTime() - attemptStarted) / 1_000_000}")
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 18))
            synchronized(lifecycleLock) {
                if (userClosed || !running.get()) return false
                output = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 1 shl 16))
            }

            // hello
            val offered = supportedCodecs(width, height)
            var negotiated = false
            val hello = JSONObject()
                .put("magic", "DSXP")
                .put("version", 1)
                .put("width", width)
                .put("height", height)
                .put("maxRefresh", maxRefresh)
                .put("codecs", org.json.JSONArray(VideoCodec.entries.filter { it in offered }.map { it.wire }))
                .put("preferredCodec", preferredCodec().wire)
                .put("name", android.os.Build.MODEL)
            if (clipboardEnabled()) hello.put("clipboard", true)
            if (micEnabled()) hello.put("mic", true)
            sendFrame(0x00, hello.toString().toByteArray())
            log("hello queued version=1 width=$width height=$height maxRefresh=$maxRefresh clipboard=${clipboardEnabled()} mic=${micEnabled()}")

            while (running.get() && !userClosed) {
                val type = input.read()
                if (type < 0) throw java.io.EOFException("EOF reading frame header")
                val len = input.readInt()
                if (len < 0 || len > 64_000_000) throw java.io.IOException("invalid framing length=$len")
                val payload = ByteArray(len)
                var off = 0
                while (off < len) {
                    val n = input.read(payload, off, len - off)
                    if (n < 0) throw java.io.EOFException("EOF reading frame body")
                    off += n
                }
                when (type) {
                    0x00 -> {
                        val ack = try { JSONObject(String(payload)) } catch (_: org.json.JSONException) {
                            throw java.io.IOException("invalid control JSON")
                        }
                        log("ack ok=${ack.optBoolean("ok")} width=${ack.optInt("width")} height=${ack.optInt("height")} fps=${ack.optInt("fps")}")
                        val selected = CodecNegotiation.accept(ack, offered, supportedCodecs)
                        ack.put("codec", selected.wire)
                        negotiated = true
                        log("negotiated codec=${selected.wire}")
                        listener.onAck(ack)
                    }
                    0x01 -> if (negotiated) listener.onVideoFrame(payload, false)
                    0x03 -> runCatching {
                        val json = JSONObject(String(payload))
                        latency?.onHostStats(json)
                        listener.onStats(json)
                    }
                    // Video timing JSON immediately preceding its 0x01 frame.
                    0x05 -> runCatching { latency?.onVideoTiming(JSONObject(String(payload))) }
                    0x04 -> if (negotiated) listener.onAudio(payload)
                    // Clipboard: the 1 MiB cap applies to the text itself, so
                    // check the decoded text (the JSON envelope adds ~30 bytes).
                    // Drops log size only, never content.
                    0x06 -> if (negotiated) try {
                        val json = JSONObject(String(payload, Charsets.UTF_8))
                        val text = json.optString("text")
                        val textBytes = text.toByteArray(Charsets.UTF_8).size
                        if (textBytes > ClipboardSyncCore.MAX_BYTES) {
                            log("clipboard in dropped bytes=$textBytes reason=over-cap")
                        } else listener.onClipboard(text, json.optString("hash"))
                    } catch (e: org.json.JSONException) {
                        log("clipboard in dropped reason=invalid-json")
                    }
                }
            }
            return true
        } catch (e: CodecNegotiation.Rejected) {
            disconnectReason = e.message ?: "Codec negotiation failed"
            running.set(false)
            sendExecutor.shutdownNow()
            listener.onRejected(e)
            return false
        } catch (e: Exception) {
            // Preserve explicit send/surface/manual reasons instead of replacing
            // them with the SocketException caused by closing that socket.
            if (disconnectReason == "EOF") disconnectReason = "${if (e is java.net.SocketTimeoutException) "read/connect timeout " else ""}${e.javaClass.name}: ${e.message.orEmpty()}"
            if (!running.get()) return true // deliberate close, not a failure
            return established
        } finally {
            log("disconnected durationMs=${(System.nanoTime() - attemptStarted) / 1_000_000} reason=$disconnectReason")
            closeInternal()
        }
    }

    fun sendInput(json: JSONObject) {
        // "ts" (android uptime ns) enables the host's input-transit probe.
        latency?.stampOutgoingInput(json)
        sendFrame(0x02, json.toString().toByteArray())
    }

    /** Remote control commands (setMode/setLogical/setFps), type 0x00. */
    fun sendCommand(json: JSONObject) = sendFrame(0x00, json.toString().toByteArray())

    /** Outgoing clipboard sync, frame 0x06. Non-blocking: queued to sendExecutor. */
    fun sendClipboard(text: String, hash: String) {
        val json = JSONObject().put("v", 1).put("text", text).put("hash", hash)
        sendFrame(0x06, json.toString().toByteArray(Charsets.UTF_8))
    }

    /**
     * Mic capture frame (0x07, docs/mic-0x07.md). Non-blocking: queued to
     * sendExecutor like every other send. Returns false — and sends nothing —
     * when the backlog is full or the session is down. Payload bytes go only
     * to the socket; nothing is logged.
     */
    fun sendMic(payload: ByteArray): Boolean {
        if (userClosed || !running.get()) return false
        if (micBacklog.get() >= MIC_MAX_BACKLOG_FRAMES) {
            if (!micDropLogged) { micDropLogged = true; log("mic send dropped reason=backlog") }
            return false
        }
        micBacklog.incrementAndGet()
        micDropLogged = false
        sendFrame(0x07, payload) { micBacklog.decrementAndGet() }
        return true
    }

    fun sendStats(json: JSONObject) {
        // "t1" (android uptime ns) drives the NTP-lite clock sync exchange.
        latency?.stampOutgoingStats(json)
        sendFrame(0x03, json.toString().toByteArray())
    }

    /** Refresh the session after Android recreates a decoder surface. */
    fun requestReconnect() {
        synchronized(lifecycleLock) {
            disconnectReason = "surface-requestReconnect"
            log(disconnectReason)
            runCatching { socket?.close() }
        }
    }

    private fun sendFrame(type: Int, payload: ByteArray, sent: (() -> Unit)? = null) {
        if (userClosed || !running.get()) { sent?.invoke(); return }
        val target = output ?: run { sent?.invoke(); return }
        try { sendExecutor.execute {
            try {
                synchronized(sendLock) {
                    // Never replay queued input into a subsequent connection.
                    if (userClosed || output !== target) return@execute
                    val out = target
                    try {
                        out.write(type)
                        out.writeInt(payload.size)
                        out.write(payload)
                        out.flush()
                    } catch (e: Exception) {
                        synchronized(lifecycleLock) {
                            if (output === target) {
                                disconnectReason = "send failure ${e.javaClass.name}: ${e.message.orEmpty()}"
                                log(disconnectReason)
                                runCatching { socket?.close() }
                            }
                        }
                    }
                }
            } finally { sent?.invoke() }
        } } catch (_: java.util.concurrent.RejectedExecutionException) { sent?.invoke() }
    }

    fun close() {
        synchronized(lifecycleLock) {
            if (userClosed) return
            disconnectReason = "manual-close"
            log(disconnectReason)
            userClosed = true; running.set(false)
        }
        closeInternal()
        networkThread?.interrupt()
        sendExecutor.shutdownNow()
    }

    private fun closeInternal() {
        val old = synchronized(lifecycleLock) {
            output = null
            socket.also { socket = null }
        }
        // Do not wait for sendLock: blocked writes must not block UI cancellation.
        runCatching { old?.close() }
    }
}
