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
    private val preferredCodec: () -> VideoCodec = { VideoCodec.HEVC }
) {
    interface Listener {
        fun onAck(config: JSONObject)
        fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean)
        fun onAudio(pcm: ByteArray) {}
        fun onStats(stats: JSONObject)
        fun onDisconnected(reason: String?)
        /** Terminal handshake error: do not retry an unsupported decoder forever. */
        fun onRejected(reason: String) { onDisconnected(reason) }
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
    private fun log(event: String) {
        runCatching { diagnostics("session=$sessionId attempt=$attempt $event") }
    }
    companion object { private val nextSession = java.util.concurrent.atomic.AtomicLong() }

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
            sendFrame(0x00, hello.toString().toByteArray())
            log("hello queued version=1 width=$width height=$height maxRefresh=$maxRefresh")

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
                }
            }
            return true
        } catch (e: CodecNegotiation.Rejected) {
            disconnectReason = e.message ?: "Codec negotiation failed"
            running.set(false)
            sendExecutor.shutdownNow()
            listener.onRejected(disconnectReason)
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

    private fun sendFrame(type: Int, payload: ByteArray) {
        if (userClosed || !running.get()) return
        val target = output ?: return
        try { sendExecutor.execute {
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
        } } catch (_: java.util.concurrent.RejectedExecutionException) { /* closed */ }
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
