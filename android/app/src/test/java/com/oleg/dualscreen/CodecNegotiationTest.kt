package com.oleg.dualscreen

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CodecNegotiationTest {
    private val both = VideoCodec.entries.toSet()

    @Test fun acceptsCanonicalAvcAndHevcAndLegacyHevcRegardlessOfPreference() {
        for (codec in VideoCodec.entries) {
            assertEquals(codec, CodecNegotiation.accept(JSONObject().put("ok", true).put("codec", codec.wire), both) { _, _ -> both })
            assertEquals(codec.mime, if (codec == VideoCodec.H264) "video/avc" else "video/hevc")
        }
        assertEquals(VideoCodec.HEVC, CodecNegotiation.accept(JSONObject().put("ok", true), both) { _, _ -> both })
        assertEquals(VideoCodec.HEVC, VideoCodec.preference(null))
        assertEquals(VideoCodec.HEVC, VideoCodec.preference("corrupt"))
        assertEquals(VideoCodec.H264, VideoCodec.preference("h264"))
        assertNull(VideoCodec.parse("avc"))
    }

    @Test fun rechecksActualAckDimensionsBeforeDecoderOwnerSeesConfig() {
        var checked = 0 to 0
        val ack = JSONObject().put("ok", true).put("codec", "h264").put("width", 2944).put("height", 1840)
        try {
            CodecNegotiation.accept(ack, both) { w, h -> checked = w to h; emptySet() }
            fail("unsupported actual session dimensions accepted")
        } catch (_: CodecNegotiation.Rejected) {}
        assertEquals(2944 to 1840, checked)
    }

    @Test fun noAdvertisedDecoderAndInvalidDimensionsAreRejected() {
        for (ack in listOf(JSONObject().put("ok", true).put("codec", "h264"), JSONObject().put("ok", true).put("width", -1))) {
            try { CodecNegotiation.accept(ack, emptySet()) { _, _ -> both }; fail("invalid negotiation accepted") }
            catch (_: CodecNegotiation.Rejected) {}
        }
    }
}
