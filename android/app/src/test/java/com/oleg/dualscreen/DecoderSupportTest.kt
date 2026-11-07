package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class DecoderSupportTest {
    @Test fun advertisesOnlyDecodersThatSupportRequestedSessionSize() {
        val queries = mutableListOf<String>()
        val support = DecoderSupport { codec, w, h ->
            queries.add("${codec.wire}:$w:$h")
            if (codec == VideoCodec.H264 && w <= 1920 && h <= 1200) "avc.decoder" else null
        }
        assertEquals(setOf(VideoCodec.H264), support.supported(1920, 1200))
        assertTrue(support.supported(2944, 1840).isEmpty())
        assertNull(support.decoderName(VideoCodec.HEVC, 1920, 1200))
        assertEquals("avc.decoder", support.decoderName(VideoCodec.H264, 1920, 1200))
        assertTrue(queries.contains("hevc:2944:1840"))
        val broken = DecoderSupport { _, _, _ -> throw IllegalArgumentException("broken vendor") }
        assertTrue(broken.supported(1920,1200).isEmpty())
    }
}
