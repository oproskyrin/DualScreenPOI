package com.oleg.dualscreen

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class DsxpConnectionTest {
    private val listener = object : DsxpConnection.Listener {
        override fun onAck(config: JSONObject) {}
        override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {}
        override fun onStats(stats: JSONObject) {}
        override fun onDisconnected(reason: String?) {}
    }
    @Test fun diagnosticReasonsSurviveTimeoutSendFailureAndSurfaceReconnect() {
        for (mode in listOf("timeout", "send", "surface")) {
            val events = java.util.concurrent.CopyOnWriteArrayList<String>()
            val reading = CountDownLatch(1)
            val closed = CountDownLatch(1)
            val disconnected = CountDownLatch(1)
            var reason = ""
            val socket = object : Socket() {
                override fun connect(endpoint: SocketAddress?, timeout: Int) {}
                override fun getInputStream() = object : java.io.InputStream() {
                    override fun read(): Int {
                        reading.countDown()
                        if (mode == "timeout") throw java.net.SocketTimeoutException("Read timed out")
                        closed.await(2, TimeUnit.SECONDS)
                        throw SocketException("read closed")
                    }
                }
                override fun getOutputStream(): java.io.OutputStream = if (mode != "send") java.io.ByteArrayOutputStream() else object : java.io.OutputStream() {
                    override fun write(value: Int) { throw java.io.IOException("write broken") }
                }
                override fun close() { closed.countDown(); super.close() }
            }
            val connection = DsxpConnection("192.0.2.1", 7381, object : DsxpConnection.Listener {
                override fun onAck(config: JSONObject) {}
                override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {}
                override fun onStats(stats: JSONObject) {}
                override fun onDisconnected(value: String?) { reason = value.orEmpty(); disconnected.countDown() }
            }, diagnostics = { events.add(it) }) { socket }
            try {
                connection.connect(100, 100, 60)
                assertTrue(reading.await(2, TimeUnit.SECONDS))
                if (mode == "surface") connection.requestReconnect()
                assertTrue(disconnected.await(3, TimeUnit.SECONDS))
                val expected = when (mode) {
                    "timeout" -> "java.net.SocketTimeoutException: Read timed out"
                    "send" -> "send failure java.io.IOException: write broken"
                    else -> "surface-requestReconnect"
                }
                assertTrue("actual: $reason", reason.contains(expected))
                assertTrue(events.any { it.contains(expected) && it.contains("durationMs=") })
            } finally { connection.close(); socket.close() }
        }
    }
    @Test fun closeInterruptsPendingConnectAndDoesNotRetry() {
        val entered = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val attempts = AtomicInteger()
        val socket = object : Socket() {
            override fun connect(endpoint: SocketAddress?, timeout: Int) {
                attempts.incrementAndGet(); entered.countDown()
                closed.await(3, TimeUnit.SECONDS)
                throw SocketException("cancelled")
            }
            override fun close() { closed.countDown(); super.close() }
        }
        val connection = DsxpConnection("192.0.2.1", 7381, listener) { socket }
        try {
            connection.connect(2944, 1840, 120)
            assertTrue("connect started", entered.await(2, TimeUnit.SECONDS))
            connection.close()
            assertTrue("close must close the socket while connect is blocked", closed.await(200, TimeUnit.MILLISECONDS))
            Thread.sleep(150)
            assertEquals(1, attempts.get())
        } finally { socket.close(); connection.close() }
    }
}
