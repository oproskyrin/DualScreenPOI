package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class ConnectionSessionTest {
    @Test fun cancellationRejectsOldCallbacksAndAutopilot() {
        val session = ConnectionSession()
        val token = session.begin()
        session.cancel()
        assertFalse(session.accepts(token))
        assertFalse(session.allowAutoconnect)
        val fresh = session.begin()
        assertTrue(session.accepts(fresh))
        assertFalse(session.accepts(token))
    }
}
