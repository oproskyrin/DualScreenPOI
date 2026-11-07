package com.oleg.dualscreen

import org.json.JSONObject

/** Validate before forwarding any ack to the MediaCodec owner. */
object CodecNegotiation {
    class Rejected(message: String) : Exception(message)

    fun accept(ack: JSONObject, offered: Set<VideoCodec>, supportedAtSize: (Int, Int) -> Set<VideoCodec>): VideoCodec {
        if (ack.opt("ok") != true) throw Rejected("Mac отклонил подключение: ${ack.optString("error", "неверный ответ")}")
        val codec = if (!ack.has("codec")) VideoCodec.HEVC else
            (ack.opt("codec") as? String)?.let(VideoCodec::parse)
                ?: throw Rejected("Mac выбрал неизвестный видеокодек")
        val w = ack.optInt("width", 2944)
        val h = ack.optInt("height", 1840)
        if (w !in 1..16384 || h !in 1..16384) throw Rejected("Mac прислал неверный размер видео")
        if (codec !in offered || codec !in supportedAtSize(w, h))
            throw Rejected("${codec.label} не поддерживается декодером для $w × $h. Выберите другой кодек или разрешение.")
        return codec
    }
}
