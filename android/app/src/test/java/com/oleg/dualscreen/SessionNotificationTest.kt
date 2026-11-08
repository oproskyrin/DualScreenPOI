package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test

class SessionNotificationTest {
    private val ru = ResourceTestStrings("values-ru")
    private val en = ResourceTestStrings("values")
    @Test fun quietUpdatesAreDistinctAndThrottledButPhaseChangesAreImmediate() {
        val gate = SessionNotificationUpdates(ru)
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
        assertEquals("DualScreen · Wi-Fi · Восстанавливаем связь…", status.title(ru))
        assertFalse(status.detail(ru).contains("fps"))
        assertTrue(status.detail(ru).contains("mac.local:7381"))
        val connected = status.copy(phase = SessionPhase.CONNECTED, configuredFps = null, decoderFps = Double.NaN)
        assertTrue(connected.detail(ru).contains("Зеркало"))
        assertTrue(connected.detail(ru).contains("На Mac задано: — fps"))
        assertTrue(connected.detail(ru).contains("Декодер: — fps"))
    }

    @Test fun aLanguageChangeRefreshesNotificationTextEvenWhenSessionFactsAreIdentical() {
        var language: UiStrings = en
        val gate = SessionNotificationUpdates(UiStrings { id, args -> language.get(id, *args) })
        val status = SessionNotificationStatus(Endpoint.USB, false, SessionPhase.CONNECTED)
        assertTrue(gate.shouldPost(status, 0))
        language = ru
        assertTrue(gate.shouldPost(status, 100))
        assertFalse(gate.shouldPost(status, 5000))
    }

    @Test fun englishNotificationUsesSameSessionFactsWithoutStaleReconnectMetrics() {
        val status = SessionNotificationStatus(Endpoint.USB, false, SessionPhase.CONNECTED,
            mirror = false, configuredFps = 120, decoderFps = 58.6)
        assertEquals("DualScreen · USB · Connected", status.title(en))
        assertEquals("Mac · 127.0.0.1:7381 (USB tunnel)\nExtend · Mac configured: 120 fps\nDecoder: 59 fps (last sample)", status.detail(en))
        for (strings in listOf(en, ru)) {
            val reconnect = status.copy(phase = SessionPhase.RECONNECTING)
            assertFalse(reconnect.detail(strings).contains("fps"))
            assertTrue(reconnect.detail(strings).contains("127.0.0.1:7381"))
            val missing = status.copy(mirror = null, configuredFps = -1, decoderFps = Double.POSITIVE_INFINITY)
            assertTrue(missing.detail(strings).contains("— fps"))
        }
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
        assertEquals("DualScreen · USB · Подключено", status.title(ru))
        assertEquals("Mac · 127.0.0.1:7381 (USB-туннель)\nРасширение · На Mac задано: 120 fps\nДекодер: 59 fps (последний замер)", status.detail(ru))
    }
}
