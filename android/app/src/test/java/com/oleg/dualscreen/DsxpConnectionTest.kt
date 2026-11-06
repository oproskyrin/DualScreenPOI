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
