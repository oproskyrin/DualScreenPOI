package com.oleg.dualscreen

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Real loopback protocol tests: rejected acks must never reach a decoder owner. */
class CodecProtocolTest {
    @Test fun rejectsBadCodecErrorAndLegacyWithoutHevcWithoutDeliveringVideoOrRetrying() {
        for (ack in listOf("{\"ok\":false,\"error\":\"no common codec\"}", "{\"ok\":true,\"codec\":\"vp9\"}",
            "{\"ok\":true,\"codec\":null}", "{\"ok\":true,\"codec\":\"HEVC\"}", "{\"ok\":true}")) {
            val rejected = CountDownLatch(1)
            val acks = AtomicInteger()
            val frames = AtomicInteger()
            var reason = ""
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
                server.soTimeout = 2000
                val client = DsxpConnection("127.0.0.1", server.localPort, object : DsxpConnection.Listener {
                    override fun onAck(config: JSONObject) { acks.incrementAndGet() }
                    override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) { frames.incrementAndGet() }
                    override fun onStats(stats: JSONObject) {}
                    override fun onDisconnected(reason: String?) {}
                    override fun onRejected(value: String) { reason = value; rejected.countDown() }
                }, supportedCodecs = { _, _ -> setOf(VideoCodec.H264) }, preferredCodec = { VideoCodec.H264 })
                try {
                    client.connect(1920, 1200, 120)
                    server.accept().use { peer ->
                        peer.soTimeout = 2000
                        val input = DataInputStream(peer.getInputStream())
                        input.readUnsignedByte(); val bytes = ByteArray(input.readInt()); input.readFully(bytes)
                        val hello = JSONObject(String(bytes))
                        assertEquals("h264", hello.getString("preferredCodec"))
                        assertEquals("[\"h264\"]", hello.getJSONArray("codecs").toString())
                        val out = DataOutputStream(peer.getOutputStream())
                        fun send(type: Int, body: ByteArray) { out.write(type); out.writeInt(body.size); out.write(body); out.flush() }
                        send(1, byteArrayOf(1)) // pre-ack video is not a negotiated stream
                        send(0, ack.toByteArray())
                        assertTrue("not rejected: $ack", rejected.await(2, TimeUnit.SECONDS))
                        assertEquals(0, acks.get()); assertEquals(0, frames.get())
                        assertTrue(reason.isNotBlank())
                        if (ack.contains("no common codec")) assertTrue(reason.contains("no common codec"))
                    }
                    server.soTimeout = 1200
                    try { server.accept().use {}; fail("terminal codec failure retried") } catch (_: SocketTimeoutException) {}
                } finally { client.close() }
            }
        }
    }
}
