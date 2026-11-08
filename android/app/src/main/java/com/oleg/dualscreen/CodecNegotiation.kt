package com.oleg.dualscreen

import org.json.JSONObject

/** Validate before forwarding any ack to the MediaCodec owner. Errors are facts, not UI text. */
object CodecNegotiation {
    enum class Failure { HOST_REJECTED, UNKNOWN_CODEC, INVALID_SIZE, UNSUPPORTED_SIZE }
    class Rejected(
        val failure: Failure,
        message: String,
        val hostError: String? = null,
        val codec: VideoCodec? = null,
        val width: Int = 0,
        val height: Int = 0
    ) : Exception(message)

    fun accept(ack: JSONObject, offered: Set<VideoCodec>, supportedAtSize: (Int, Int) -> Set<VideoCodec>): VideoCodec {
        if (ack.opt("ok") != true) {
            val error = ack.optString("error", "invalid response")
            throw Rejected(Failure.HOST_REJECTED, "Mac rejected connection: $error", hostError = error)
        }
        val codec = if (!ack.has("codec")) VideoCodec.HEVC else
            (ack.opt("codec") as? String)?.let(VideoCodec::parse)
                ?: throw Rejected(Failure.UNKNOWN_CODEC, "Mac selected an unknown video codec")
        val w = ack.optInt("width", 2944)
        val h = ack.optInt("height", 1840)
        if (w !in 1..16384 || h !in 1..16384)
            throw Rejected(Failure.INVALID_SIZE, "Mac sent invalid video dimensions")
        if (codec !in offered || codec !in supportedAtSize(w, h))
            throw Rejected(Failure.UNSUPPORTED_SIZE, "Unsupported decoder codec=${codec.wire} width=$w height=$h",
                codec = codec, width = w, height = h)
        return codec
    }
}
