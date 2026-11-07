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

/** Actual loopback TCP, not fabricated DSXP responses from a mock transport. */
class DsxpProtocolTest {
    @Test fun diagnosticsPreserveEofInvalidFramingAndReconnectReasonWithoutPayloads() {
        for (invalid in listOf(false, true)) {
            val events = java.util.concurrent.CopyOnWriteArrayList<String>()
            val ended = CountDownLatch(1)
            var reason: String? = null
            val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
            server.soTimeout = 2000
            val client = DsxpConnection("127.0.0.1", server.localPort, object : DsxpConnection.Listener {
                override fun onAck(config: JSONObject) {}
                override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) {}
                override fun onStats(stats: JSONObject) {}
                override fun onDisconnected(value: String?) { reason = value; ended.countDown() }
            }, diagnostics = { events.add(it) })
            try {
                client.connect(100, 100, 60)
                server.accept().use { peer ->
                    val input = DataInputStream(peer.getInputStream())
                    input.readUnsignedByte(); val bytes = ByteArray(input.readInt()); input.readFully(bytes)
                    if (invalid) DataOutputStream(peer.getOutputStream()).apply { write(1); writeInt(-1); flush() }
                }
                assertTrue(ended.await(2, TimeUnit.SECONDS))
                assertTrue(reason!!.contains(if (invalid) "invalid framing" else "EOF"))
                assertTrue(events.any { it.contains("attempt=1") && it.contains("connected") })
                assertTrue(events.any { it.contains("durationMs=") && it.contains("disconnected") })
                assertTrue(events.any { it.contains("retry") && it.contains("backoffMs=1000") })
                assertFalse(events.any { it.contains("magic") || it.contains("payload") })
                client.close()
                assertTrue(events.any { it.contains("manual-close") })
            } finally { client.close(); server.close() }
        }
    }
    @Test fun exchangesHelloControlInputStatsAudioAndStopsReconnectingAfterClose() {
        val ack = CountDownLatch(1)
        val video = CountDownLatch(1)
        val audio = CountDownLatch(1)
        val stats = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val events = java.util.concurrent.CopyOnWriteArrayList<String>()
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        server.soTimeout = 2000
        val client = DsxpConnection("127.0.0.1", server.localPort, object : DsxpConnection.Listener {
            override fun onAck(config: JSONObject) { if (config.optBoolean("ok")) ack.countDown() }
            override fun onVideoFrame(annexB: ByteArray, isKeyframeHint: Boolean) { if (annexB.contentEquals(byteArrayOf(1, 2))) video.countDown() }
            override fun onAudio(pcm: ByteArray) { if (pcm.contentEquals(byteArrayOf(3, 4))) audio.countDown() }
            override fun onStats(statsValue: JSONObject) { if (statsValue.optInt("hostFps") == 120) stats.countDown() }
            override fun onDisconnected(reason: String?) { disconnected.countDown() }
        }, diagnostics = { events.add(it) })
        try {
            client.connect(2944, 1840, 120)
            server.accept().use { peer ->
                peer.soTimeout = 2000
                val input = DataInputStream(peer.getInputStream())
                val output = DataOutputStream(peer.getOutputStream())
                fun read(): Pair<Int, ByteArray> {
                    val type = input.readUnsignedByte(); val bytes = ByteArray(input.readInt()); input.readFully(bytes)
                    return type to bytes
                }
                fun send(type: Int, bytes: ByteArray) { output.write(type); output.writeInt(bytes.size); output.write(bytes); output.flush() }
                val hello = read()
                assertEquals(0, hello.first)
                val json = JSONObject(String(hello.second))
                assertEquals("DSXP", json.getString("magic")); assertEquals(2944, json.getInt("width")); assertEquals(120, json.getInt("maxRefresh"))
                assertEquals("hevc", json.getString("preferredCodec"))
                assertEquals(listOf("hevc"), (0 until json.getJSONArray("codecs").length()).map { json.getJSONArray("codecs").getString(it) })
                send(0, "{\"ok\":true}".toByteArray())
                send(1, byteArrayOf(1, 2)); send(4, byteArrayOf(3, 4)); send(3, "{\"hostFps\":120}".toByteArray())
                assertTrue(ack.await(2, TimeUnit.SECONDS)); assertTrue(video.await(2, TimeUnit.SECONDS))
                assertTrue(audio.await(2, TimeUnit.SECONDS)); assertTrue(stats.await(2, TimeUnit.SECONDS))
                client.sendCommand(JSONObject().put("cmd", "setMode").put("mode", "extend"))
                client.sendInput(JSONObject().put("t", "key").put("ch", "я"))
                client.sendStats(JSONObject().put("latencyMs", 15).put("fps", 120))
                assertEquals(0, read().first); assertEquals(2, read().first); assertEquals(3, read().first)
                val state = PhysicalInputState()
                val key = state.key(1, 29, true, 0, 0, 100, "я")!!
                client.sendInput(key)
                val wireKey = read()
                assertEquals(2, wireKey.first)
                assertEquals("hardwareKey", JSONObject(String(wireKey.second)).getString("t"))
                assertEquals("я", JSONObject(String(wireKey.second)).getString("text"))
                val pointer = state.pointer("button", 2, true, .2, .7, 0).single()
                client.sendInput(pointer)
                val wirePointer = read()
                assertEquals(2, wirePointer.first)
                assertEquals("right", JSONObject(String(wirePointer.second)).getString("button"))
                client.sendInput(state.reset(200))
                assertEquals("inputReset", JSONObject(String(read().second)).getString("t"))
                assertTrue(events.any { it.contains("ack ok=true") })
                assertFalse(events.any { it.contains("я") || it.contains("hardwareKey") || it.contains("code=") })
            }
            assertTrue(disconnected.await(2, TimeUnit.SECONDS))
            client.close()
            server.soTimeout = 1250
            try { server.accept().use {}; fail("cancel must prevent the retry") } catch (_: SocketTimeoutException) { }
        } finally { client.close(); server.close() }
    }
}
