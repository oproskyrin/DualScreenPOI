package com.oleg.dualscreen

import kotlin.math.roundToInt

enum class SessionPhase { CONNECTING, CONNECTED, RECONNECTING }

/** Immutable facts about the Activity-owned session, never a request to connect. */
data class SessionNotificationStatus(
    val endpoint: Endpoint,
    val wifi: Boolean,
    val phase: SessionPhase,
    val mirror: Boolean? = null,
    val configuredFps: Int? = null,
    val decoderFps: Double? = null
) {
    fun title(strings: UiStrings): String = strings.get(R.string.notification_title,
        if (wifi) "Wi-Fi" else "USB", strings.get(when (phase) {
            SessionPhase.CONNECTING -> R.string.connecting
            SessionPhase.CONNECTED -> R.string.phase_connected
            SessionPhase.RECONNECTING -> R.string.phase_reconnecting
        }))

    fun detail(strings: UiStrings): String {
        val address = strings.get(if (wifi) R.string.notification_wifi_address else R.string.notification_usb_address, endpoint.address)
        // During reconnect, the old ack and decoder sample are no longer current.
        if (phase != SessionPhase.CONNECTED) return strings.get(R.string.notification_pending, address)
        val mode = strings.get(when (mirror) { true -> R.string.mode_mirror; false -> R.string.mode_extend; null -> R.string.mode_unknown })
        val configured = configuredFps?.takeIf { it > 0 }?.toString() ?: "—"
        val actual = decoderFps?.takeIf { it.isFinite() && it >= 0 }?.roundToInt()?.toString() ?: "—"
        return strings.get(R.string.notification_detail, address, mode, configured, actual)
    }
}
