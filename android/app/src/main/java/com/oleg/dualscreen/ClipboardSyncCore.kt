package com.oleg.dualscreen

import java.security.MessageDigest

/**
 * Pure loop-suppression core for DSXP clipboard sync (frame 0x06), shared by
 * the outgoing listener and the incoming frame handler. Never touches Android
 * clipboard APIs, so it is unit-testable. Clipboard text is never passed to
 * ClientLog — callers log sizes and hashes only.
 */
class ClipboardSyncCore(private val nowMs: () -> Long = System::currentTimeMillis) {

    sealed interface LocalDecision {
        /** Send frame 0x06 with this text/hash. */
        data class Send(val text: String, val hash: String) : LocalDecision
        /** Hash matches lastKnownHash — an echo of our own or an applied clip. */
        object Echo : LocalDecision
        /** Text exceeds the 1 MiB wire cap; dropped (log size only). */
        object Oversized : LocalDecision
        /** Within the 300 ms rate limit; caller retries with the latest clip. */
        object RateLimited : LocalDecision
    }

    private var lastKnownHash: String? = null
    private var lastSentAtMs = Long.MIN_VALUE / 2

    /** Local clipboard changed. Returns the decision for the outgoing frame. */
    @Synchronized
    fun onLocalChange(text: String): LocalDecision {
        if (text.isEmpty()) return LocalDecision.Echo
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES) return LocalDecision.Oversized
        val hash = hash16(bytes)
        if (hash == lastKnownHash) return LocalDecision.Echo
        val now = nowMs()
        if (now - lastSentAtMs < RATE_LIMIT_MS) return LocalDecision.RateLimited
        lastSentAtMs = now
        lastKnownHash = hash
        return LocalDecision.Send(text, hash)
    }

    /**
     * Incoming 0x06. Returns true when the text must be applied locally;
     * false when it is the echo of a clip we just set. lastKnownHash is
     * updated here so the programmatic set is suppressed on the way out.
     */
    @Synchronized
    fun onIncoming(text: String, hash: String): Boolean {
        if (text.isEmpty() || hash == lastKnownHash) return false
        lastKnownHash = hash
        return true
    }

    companion object {
        const val MAX_BYTES = 1 shl 20
        const val RATE_LIMIT_MS = 300L

        /** First 16 hex chars of sha256 over UTF-8 bytes; loop detection only. */
        fun hash16(text: String): String = hash16(text.toByteArray(Charsets.UTF_8))

        fun hash16(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .take(8)
                .joinToString("") { "%02x".format(it) }
    }
}
