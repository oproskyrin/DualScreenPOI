package com.oleg.dualscreen

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LocalizedErrorsTest {
    private fun reject(ack: JSONObject, supported: Set<VideoCodec> = VideoCodec.entries.toSet()): CodecNegotiation.Rejected {
        try {
            CodecNegotiation.accept(ack, supported) { _, _ -> supported }
            throw AssertionError("Invalid negotiation accepted")
        } catch (error: CodecNegotiation.Rejected) { return error }
    }

    @Test fun codecFailuresRenderFromBothRealResourceCatalogsWithoutChangingDiagnosticFacts() {
        val host = reject(JSONObject().put("ok", false).put("error", "no common codec"))
        val unknown = reject(JSONObject().put("ok", true).put("codec", "vp9"))
        val invalid = reject(JSONObject().put("ok", true).put("width", -1))
        val unsupported = reject(JSONObject().put("ok", true).put("codec", "h264").put("width", 2000).put("height", 1000), setOf(VideoCodec.HEVC))
        assertEquals(CodecNegotiation.Failure.HOST_REJECTED, host.failure)
        assertEquals("no common codec", host.hostError)
        assertEquals(CodecNegotiation.Failure.UNKNOWN_CODEC, unknown.failure)
        assertEquals(CodecNegotiation.Failure.INVALID_SIZE, invalid.failure)
        assertEquals(CodecNegotiation.Failure.UNSUPPORTED_SIZE, unsupported.failure)
        assertEquals(VideoCodec.H264, unsupported.codec)
        assertEquals(2000, unsupported.width)
        assertEquals(1000, unsupported.height)
        val en = ResourceTestStrings("values")
        val ru = ResourceTestStrings("values-ru")
        assertEquals("Your Mac rejected the connection: no common video codec", host.localized(en))
        assertEquals("Mac отклонил подключение: нет общего видеокодека", host.localized(ru))
        assertEquals("Your Mac selected an unknown video codec", unknown.localized(en))
        assertEquals("Mac выбрал неизвестный видеокодек", unknown.localized(ru))
        assertEquals("Your Mac sent an invalid video size", invalid.localized(en))
        assertEquals("Mac прислал неверный размер видео", invalid.localized(ru))
        for (strings in listOf(en, ru)) {
            val text = unsupported.localized(strings)
            assertTrue(text.contains("H.264"))
            assertTrue(text.contains("2000 × 1000"))
        }
        assertEquals("Mac rejected connection: no common codec", host.message)
    }

    @Test fun unknownHostErrorsRemainExactInMetadataButUseLocalizedUserGuidance() {
        val error = reject(JSONObject().put("ok", false).put("error", "future server error"))
        assertEquals("Mac rejected connection: future server error", error.message)
        for (qualifier in listOf("values", "values-ru")) {
            val strings = ResourceTestStrings(qualifier)
            assertEquals(strings.get(R.string.error_host_generic), error.localized(strings))
            val pipeline = reject(JSONObject().put("ok", false).put("error", "Display pipeline unavailable"))
            assertEquals(strings.get(R.string.error_pipeline), pipeline.localized(strings))
        }
    }
}
