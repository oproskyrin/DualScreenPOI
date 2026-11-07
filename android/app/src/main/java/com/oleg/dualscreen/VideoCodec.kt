package com.oleg.dualscreen

/** Wire identifiers are deliberately strict; only absent legacy ack implies HEVC. */
enum class VideoCodec(val wire: String, val mime: String, val label: String) {
    HEVC("hevc", "video/hevc", "HEVC / H.265"),
    H264("h264", "video/avc", "H.264 / AVC");

    companion object {
        fun parse(value: String): VideoCodec? = entries.firstOrNull { it.wire == value }
        fun preference(saved: String?): VideoCodec = saved?.let(::parse) ?: HEVC
    }
}
