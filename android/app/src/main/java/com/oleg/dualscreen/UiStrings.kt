package com.oleg.dualscreen

/** Resource lookup injected at the presentation boundary; the wire/log layers stay locale-free. */
fun interface UiStrings {
    fun get(id: Int, vararg args: Any): String
}

fun CodecNegotiation.Rejected.localized(strings: UiStrings): String = when (failure) {
    CodecNegotiation.Failure.HOST_REJECTED -> when (hostError?.lowercase(java.util.Locale.ROOT)) {
        "no common codec", "no common video codec" -> strings.get(R.string.error_rejected, strings.get(R.string.error_no_common_codec))
        "display pipeline unavailable" -> strings.get(R.string.error_pipeline)
        "invalid response" -> strings.get(R.string.error_rejected, strings.get(R.string.error_invalid_response))
        // Unknown server messages remain exact in connection metadata, never guessed/translated.
        else -> strings.get(R.string.error_host_generic)
    }
    CodecNegotiation.Failure.UNKNOWN_CODEC -> strings.get(R.string.error_unknown_codec)
    CodecNegotiation.Failure.INVALID_SIZE -> strings.get(R.string.error_video_size)
    CodecNegotiation.Failure.UNSUPPORTED_SIZE -> strings.get(R.string.error_codec_size, codec?.label ?: "—", width, height)
}
