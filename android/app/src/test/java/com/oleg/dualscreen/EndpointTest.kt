package com.oleg.dualscreen
import org.junit.Assert.*
import org.junit.Test
class EndpointTest {
    @Test fun parsesHostnameAndBracketedIpv6WithoutChangingUsb() {
        assertEquals(Endpoint("mac.local"), Endpoint.parse(" mac.local "))
        assertEquals(Endpoint("192.168.1.2", 8000), Endpoint.parse("192.168.1.2:8000"))
        assertEquals(Endpoint("fe80::1%wlan0"), Endpoint.parse("[fe80::1%wlan0]:7381"))
        assertEquals("127.0.0.1:7381", Endpoint.USB.address)
    }
    @Test fun rejectsInvalidPortsAndAmbiguousOrEmptyHosts() {
        listOf("", ":7381", "host:abc", "host:0", "host:65536", "a b", "::1", "[::1", "host/path").forEach {
            assertNull(it, Endpoint.parse(it))
        }
    }
}
