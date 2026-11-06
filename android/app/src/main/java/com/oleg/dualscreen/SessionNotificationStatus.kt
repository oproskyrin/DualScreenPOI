package com.oleg.dualscreen

import kotlin.math.roundToInt

enum class SessionPhase(val label: String) {
    CONNECTING("Подключение…"), CONNECTED("Подключено"), RECONNECTING("Восстанавливаем связь…")
}

/** Immutable facts about the Activity-owned session, never a request to connect. */
data class SessionNotificationStatus(
    val endpoint: Endpoint,
    val wifi: Boolean,
    val phase: SessionPhase,
    val mirror: Boolean? = null,
    val configuredFps: Int? = null,
    val decoderFps: Double? = null
) {
    val title: String get() = "DualScreen · ${if (wifi) "Wi-Fi" else "USB"} · ${phase.label}"
    val detail: String get() {
        val address = "Mac · ${endpoint.address}${if (wifi) "" else " (USB-туннель)"}"
        // During reconnect, the old ack and decoder sample are no longer current.
        if (phase != SessionPhase.CONNECTED) return "$address\nНажмите, чтобы вернуться в DualScreen"
        val mode = when (mirror) { true -> "Зеркало"; false -> "Расширение"; null -> "Режим: —" }
        val configured = configuredFps?.takeIf { it > 0 }?.toString() ?: "—"
        val actual = decoderFps?.takeIf { it.isFinite() && it >= 0 }?.roundToInt()?.toString() ?: "—"
        return "$address\n$mode · На Mac задано: $configured fps\nДекодер: $actual fps (последний замер)"
    }
}
