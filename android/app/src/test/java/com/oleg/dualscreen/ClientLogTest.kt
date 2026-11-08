package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.io.File

class ClientLogTest {
    @Test fun serialDurableWritesRotateAndReadRecentEvents() {
        val base = File(System.getenv("TMPDIR") ?: System.getProperty("java.io.tmpdir"))
        val dir = Files.createTempDirectory(base.toPath(), "ds-log").toFile()
        try {
            val log = ClientLog({ dir }, 180)
            repeat(30) { log.event("session=1 attempt=$it connected") }
            val recent = log.recent().get()
            assertTrue(recent.contains("attempt=29 connected"))
            assertTrue(recent.contains("T"))
            assertTrue(File(dir, "connection.log.1").exists())
            assertTrue(dir.listFiles()!!.all { it.length() <= 180 })
            log.close()
            assertTrue(File(dir, "connection.log").readText().contains("attempt=29"))
        } finally { dir.deleteRecursively() }
    }
    @Test fun unavailableStorageNeverBreaksConnection() {
        val log = ClientLog({ null })
        log.event("connected")
        assertEquals("", log.recent().get()) // presentation owns the localized empty-state message
        log.close()
        assertEquals("", log.recent().get()) // a closed writer also delegates its empty state to the UI
    }
}
