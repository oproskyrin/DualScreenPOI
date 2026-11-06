package com.oleg.dualscreen

/** Session fence shared by callbacks and the UI. */
class ConnectionSession {
    @Volatile private var generation = 0L
    @Volatile private var active = false
    @Volatile var allowAutoconnect = true
        private set
    @Synchronized fun begin(): Long {
        generation++
        active = true
        allowAutoconnect = true
        return generation
    }
    @Synchronized fun cancel() {
        generation++
        active = false
        allowAutoconnect = false
    }
    fun accepts(token: Long): Boolean = active && token == generation
}
