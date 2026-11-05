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
    private val listener: Listener
) {
    interface Listener {
        fun onAck(config: JSONObject)
        fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean)
        fun onStats(stats: JSONObject)
        fun onDisconnected(reason: String?)
    }

    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    private val running = AtomicBoolean(false)
    @Volatile private var userClosed = false
    private val sendLock = Any()

    fun connect(width: Int, height: Int, maxRefresh: Int) {
        if (!running.compareAndSet(false, true)) return
        userClosed = false
        Thread({
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
        }, "dsxp-net").start()
    }

    /** One connection attempt + read loop. Returns true if a session was established. */
    private fun connectOnce(width: Int, height: Int, maxRefresh: Int): Boolean {
        try {
            val s = Socket()
            s.tcpNoDelay = true
            s.keepAlive = true
            s.receiveBufferSize = 1 shl 20
            s.connect(InetSocketAddress(host, port), 4000)
            socket = s
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 18))
            synchronized(sendLock) {
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
                }
            }
            return true
        } catch (e: Exception) {
            if (!running.get()) return true // deliberate close, not a failure
            return socket != null // had a session -> true so backoff resets
        } finally {
            closeInternal()
        }
    }

    fun sendInput(json: JSONObject) = sendFrame(0x02, json.toString().toByteArray())

    fun sendStats(json: JSONObject) = sendFrame(0x03, json.toString().toByteArray())

    private fun sendFrame(type: Int, payload: ByteArray) {
        synchronized(sendLock) {
            val out = output ?: return
            runCatching {
                out.write(type)
                out.writeInt(payload.size)
                out.write(payload)
                out.flush()
            }
        }
    }

    fun close() {
        userClosed = true
        running.set(false)
        closeInternal()
    }

    private fun closeInternal() {
        runCatching { socket?.close() }
        synchronized(sendLock) { output = null }
    }
}
