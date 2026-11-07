package com.oleg.dualscreen

/** Pure Annex-B parsing, independent of MediaCodec. */
object AnnexB {
    fun configuration(data: ByteArray, codec: VideoCodec): List<ByteArray>? {
        val nals = split(data)
        val types = if (codec == VideoCodec.H264) listOf(7, 8) else listOf(32, 33, 34)
        val sets = types.map { type -> nals.firstOrNull { type(it, codec) == type } ?: return null }
        val framed = sets.map { byteArrayOf(0, 0, 0, 1) + it }
        return if (codec == VideoCodec.H264) framed else listOf(framed.reduce { a, b -> a + b })
    }

    fun isKeyframe(data: ByteArray, codec: VideoCodec): Boolean = split(data).any {
        val t = type(it, codec)
        if (codec == VideoCodec.H264) t == 5 else t in 16..21
    }

    private fun type(nal: ByteArray, codec: VideoCodec): Int =
        if (codec == VideoCodec.H264) {
            if (nal.size < 2) -1 else nal[0].toInt() and 0x1f
        } else {
            if (nal.size < 3) -1 else (nal[0].toInt() and 0x7e) shr 1
        }
    fun split(data: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var payload = -1
        var i = 0
        while (i + 2 < data.size) {
            val length = if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                when {
                    data[i + 2] == 1.toByte() -> 3
                    i + 3 < data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte() -> 4
                    else -> 0
                }
            } else 0
            if (length == 0) { i++; continue }
            if (payload >= 0 && i > payload) result.add(data.copyOfRange(payload, i))
            payload = i + length
            i = payload
        }
        if (payload >= 0 && payload < data.size) result.add(data.copyOfRange(payload, data.size))
        return result
    }
}
