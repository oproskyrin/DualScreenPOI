package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class SessionNotificationTest {
    @Test fun quietUpdatesAreDistinctAndThrottledButPhaseChangesAreImmediate() {
        val gate = SessionNotificationUpdates()
        val status = SessionNotificationStatus(Endpoint.USB, false, SessionPhase.CONNECTED, decoderFps = 60.0)
        assertTrue(gate.shouldPost(status, 0))
        assertFalse(gate.shouldPost(status, 5000))
        assertFalse(gate.shouldPost(status.copy(decoderFps = 59.0), 1000))
        assertTrue(gate.shouldPost(status.copy(decoderFps = 59.0), 3000))
        assertTrue(gate.shouldPost(status.copy(phase = SessionPhase.RECONNECTING), 3100))
        assertTrue(gate.shouldPost(status.copy(phase = SessionPhase.CONNECTING, wifi = true), 3200))
        assertTrue(gate.shouldPost(status.copy(phase = SessionPhase.CONNECTING, wifi = true, endpoint = Endpoint("other.local", 7381)), 3300))
    }

    @Test fun reconnectDoesNotPresentOldConfigOrSampleAsCurrent() {
        val status = SessionNotificationStatus(Endpoint("mac.local", 7381), true, SessionPhase.RECONNECTING,
            mirror = true, configuredFps = 120, decoderFps = 90.0)
        assertEquals("DualScreen · Wi-Fi · Восстанавливаем связь…", status.title)
        assertFalse(status.detail.contains("fps"))
        assertTrue(status.detail.contains("mac.local:7381"))
        val connected = status.copy(phase = SessionPhase.CONNECTED, configuredFps = null, decoderFps = Double.NaN)
        assertTrue(connected.detail.contains("Зеркало"))
        assertTrue(connected.detail.contains("На Mac задано: — fps"))
        assertTrue(connected.detail.contains("Декодер: — fps"))
    }

    @Test fun ownerLifecycleCannotResurrectCancelledOrReplaceNewSession() {
        val store = SessionNotificationStore()
        val usb = SessionNotificationStatus(Endpoint.USB, false, SessionPhase.CONNECTING)
        val old = store.begin(usb)
        val fresh = store.begin(usb.copy(endpoint = Endpoint("mac.local", 7381), wifi = true))
        assertFalse(store.update(old, usb))
        assertFalse(store.end(old))
        assertEquals("mac.local", store.current?.endpoint?.host)
        assertTrue(store.update(fresh, store.current!!.copy(phase = SessionPhase.RECONNECTING)))
        assertTrue(store.end(fresh))
        assertNull(store.current)
        assertFalse(store.update(fresh, usb))
        assertNull(SessionNotificationStore().current) // process restart has no phantom session
    }

    @Test fun statusDistinguishesTransportEndpointAndMeasuredFromConfiguredRate() {
        val status = SessionNotificationStatus(Endpoint.USB, false, SessionPhase.CONNECTED,
            mirror = false, configuredFps = 120, decoderFps = 58.6)
        assertEquals("DualScreen · USB · Подключено", status.title)
        assertEquals("Mac · 127.0.0.1:7381 (USB-туннель)\nРасширение · На Mac задано: 120 fps\nДекодер: 59 fps (последний замер)", status.detail)
    }
}
