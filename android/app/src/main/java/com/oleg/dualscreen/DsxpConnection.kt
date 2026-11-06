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
    private val socketFactory: () -> Socket = { Socket() }
) {
    interface Listener {
        fun onAck(config: JSONObject)
        fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean)
        fun onAudio(pcm: ByteArray) {}
        fun onStats(stats: JSONObject)
        fun onDisconnected(reason: String?)
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
                    listener.onDisconnected("reconnect in ${backoffMs / 1000}s…")
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
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 18))
            synchronized(lifecycleLock) {
                if (userClosed || !running.get()) return false
                output = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 1 shl 16))
            }

            // hello
            val hello = JSONObject()
                .put("magic", "DSXP")
                .put("version", 1)
                .put("width", width)
                .put("height", height)
                .put("maxRefresh", maxRefresh)
                .put("name", android.os.Build.MODEL)
            sendFrame(0x00, hello.toString().toByteArray())

            while (running.get() && !userClosed) {
                val type = input.read()
                if (type < 0) break
                val len = input.readInt()
                if (len < 0 || len > 64_000_000) break
                val payload = ByteArray(len)
                var off = 0
                while (off < len) {
                    val n = input.read(payload, off, len - off)
                    if (n < 0) return true
                    off += n
                }
                when (type) {
                    0x00 -> listener.onAck(JSONObject(String(payload)))
                    0x01 -> listener.onVideoFrame(payload, false)
                    0x03 -> runCatching { listener.onStats(JSONObject(String(payload))) }
                    0x04 -> listener.onAudio(payload)
                }
            }
            return true
        } catch (e: Exception) {
            if (!running.get()) return true // deliberate close, not a failure
            return established
        } finally {
            closeInternal()
        }
    }

    fun sendInput(json: JSONObject) = sendFrame(0x02, json.toString().toByteArray())

    /** Remote control commands (setMode/setLogical/setFps), type 0x00. */
    fun sendCommand(json: JSONObject) = sendFrame(0x00, json.toString().toByteArray())

    fun sendStats(json: JSONObject) = sendFrame(0x03, json.toString().toByteArray())

    /** Refresh the session after Android recreates a decoder surface. */
    fun requestReconnect() { runCatching { socket?.close() } }

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
                        if (output === target) runCatching { socket?.close() }
                    }
                }
            }
        } } catch (_: java.util.concurrent.RejectedExecutionException) { /* closed */ }
    }

    fun close() {
        synchronized(lifecycleLock) { userClosed = true; running.set(false) }
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
