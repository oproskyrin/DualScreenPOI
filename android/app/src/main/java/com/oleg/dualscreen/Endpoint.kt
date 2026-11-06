package com.oleg.dualscreen

data class Endpoint(val host: String, val port: Int = 7381) {
    val address: String get() = if (host.contains(':')) "[$host]:$port" else "$host:$port"
    companion object {
        val USB = Endpoint("127.0.0.1")
        fun parse(value: String): Endpoint? {
            val text = value.trim()
            val match = Regex("^(?:\\[([^\\]]+)\\]|([^:\\s/\\[\\]]+))(?::([0-9]+))?$").matchEntire(text) ?: return null
            val host = match.groupValues[1].ifEmpty { match.groupValues[2] }
            if (host.isBlank() || host.any { it.isWhitespace() || it == '/' }) return null
            val portText = match.groupValues[3]
            val port = if (portText.isEmpty()) 7381 else portText.toIntOrNull() ?: return null
            if (port !in 1..65535) return null
            return Endpoint(host, port)
        }
    }
}
