package com.oleg.dualscreen

/** Process-local only: the service cannot restore a session from preferences or an intent. */
class SessionNotificationStore {
    private var owner = 0L
    var current: SessionNotificationStatus? = null
        private set

    fun begin(status: SessionNotificationStatus): Long {
        owner++
        current = status
        return owner
    }

    fun update(token: Long, status: SessionNotificationStatus): Boolean {
        if (token != owner || current == null) return false
        current = status
        return true
    }

    fun end(token: Long): Boolean {
        if (token != owner || current == null) return false
        current = null
        return true
    }
}
