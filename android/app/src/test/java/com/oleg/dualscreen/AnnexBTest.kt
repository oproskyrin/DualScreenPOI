package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class AnnexBTest {
    @Test fun truncatedHeadersNeverCountAsKeyframesOrConfiguration() {
        for (codec in VideoCodec.entries) {
            for (data in listOf(byteArrayOf(), byteArrayOf(0), byteArrayOf(0,0), byteArrayOf(0,0,1), byteArrayOf(0,0,0,1))) {
                assertTrue(AnnexB.split(data).isEmpty())
                assertFalse(AnnexB.isKeyframe(data, codec))
                assertNull(AnnexB.configuration(data, codec))
            }
        }
        assertFalse(AnnexB.isKeyframe(byteArrayOf(0,0,1,0x65), VideoCodec.H264))
        assertFalse(AnnexB.isKeyframe(byteArrayOf(0,0,1,0x26,1), VideoCodec.HEVC))
        assertNull(AnnexB.configuration(byteArrayOf(0,0,1,0x67,0,0,1,0x68), VideoCodec.H264))
    }

    @Test fun hevcConfigurationRequiresDistinctSetsInCanonicalOrderAndRecognizesIrap() {
        val vps = byteArrayOf(0,0,0,1,0x40,1,0x12)
        val sps = byteArrayOf(0,0,0,1,0x42,1,0x34)
        val pps = byteArrayOf(0,0,0,1,0x44,1,0x56)
        assertArrayEquals(vps + sps + pps, AnnexB.configuration(pps + sps + vps, VideoCodec.HEVC)!!.single())
        assertNull(AnnexB.configuration(vps + sps + sps, VideoCodec.HEVC))
        assertFalse(AnnexB.isKeyframe(vps + sps + pps, VideoCodec.HEVC))
        for (type in 16..21) assertTrue(AnnexB.isKeyframe(byteArrayOf(0,0,1,(type shl 1).toByte(),1,0x12), VideoCodec.HEVC))
        assertFalse(AnnexB.isKeyframe(byteArrayOf(0,0,1,2,1,0x12), VideoCodec.HEVC))
    }
    @Test fun avcStartupSeparatesSpsAndPpsAndRecognizesIdrWithoutParameterSets() {
        val au = byteArrayOf(0,0,1,0x68,0x34,0,0,0,1,0x67,0x12,0,0,1,0x65,0x56)
        val csd = AnnexB.configuration(au, VideoCodec.H264)!!
        assertArrayEquals(byteArrayOf(0,0,0,1,0x67,0x12), csd[0])
        assertArrayEquals(byteArrayOf(0,0,0,1,0x68,0x34), csd[1])
        assertTrue(AnnexB.isKeyframe(byteArrayOf(0,0,1,0x65,1), VideoCodec.H264))
        assertFalse(AnnexB.isKeyframe(byteArrayOf(0,0,1,0x41,1), VideoCodec.H264))
    }
    @Test fun mixedStartCodesDoNotLeakDelimiterZerosIntoPreviousNal() {
        val nals = AnnexB.split(byteArrayOf(0,0,1,0x67,0x12,0,0,0,1,0x68,0x34,0,0,1,0x65,0x56))
        assertEquals(3, nals.size)
        assertArrayEquals(byteArrayOf(0x67,0x12), nals[0])
        assertArrayEquals(byteArrayOf(0x68,0x34), nals[1])
        assertArrayEquals(byteArrayOf(0x65,0x56), nals[2])
    }
}
