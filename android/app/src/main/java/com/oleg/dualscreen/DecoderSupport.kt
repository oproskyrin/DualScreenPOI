package com.oleg.dualscreen

import android.media.MediaCodecList
import android.media.MediaFormat

/** The same dimension-aware query is used for hello, ack, and decoder creation. */
class DecoderSupport(private val query: (VideoCodec, Int, Int) -> String?) {
    fun decoderName(codec: VideoCodec, width: Int, height: Int): String? =
        if (width <= 0 || height <= 0) null else runCatching { query(codec, width, height) }.getOrNull()

    fun supported(width: Int, height: Int): Set<VideoCodec> =
        VideoCodec.entries.filter { decoderName(it, width, height) != null }.toSet()

    companion object {
        fun system(): DecoderSupport = DecoderSupport { codec, width, height ->
            // REGULAR_CODECS excludes secure/tunneled-only components that cannot
            // decode our ordinary Surface session. No frame rate is assumed.
            MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(
                MediaFormat.createVideoFormat(codec.mime, width, height))
        }
    }
}
