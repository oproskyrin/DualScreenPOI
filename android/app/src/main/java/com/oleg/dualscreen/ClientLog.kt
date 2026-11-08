package com.oleg.dualscreen

import java.io.File
import java.time.Instant
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors

/** Only connection metadata may be supplied. Never pass an input JSON or key event. */
class ClientLog(private val directory: () -> File?, private val maxBytes: Int = 512 * 1024) : AutoCloseable {
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "dsxp-log").apply { isDaemon = true } }
    fun event(metadata: String) {
        val line = "${Instant.now()} ${metadata.replace('\n', ' ').replace('\r', ' ').take(2048)}\n"
        runCatching { writer.execute {
            runCatching {
                val dir = directory() ?: return@execute
                if (!dir.isDirectory && !dir.mkdirs()) return@execute
                val current = File(dir, "connection.log")
                val bytes = line.toByteArray(Charsets.UTF_8).let { if (it.size <= maxBytes) it else it.copyOf(maxBytes) }
                if (current.length() + bytes.size > maxBytes) {
                    val old = File(dir, "connection.log.1")
                    if (old.exists() && !old.delete()) return@execute
                    if (current.exists() && !current.renameTo(old)) return@execute
                }
                current.appendBytes(bytes)
            }
        } }
    }
    fun recent(): CompletableFuture<String> {
        val result = CompletableFuture<String>()
        runCatching { writer.execute {
            result.complete(runCatching {
                val dir = directory()
                if (dir == null) "" else listOf("connection.log.1", "connection.log")
                    .map { File(dir, it) }.filter { it.isFile }.joinToString("") { it.readText() }.takeLast(24000)
            }.getOrDefault(""))
        } }.onFailure { result.complete("") }
        return result
    }
    override fun close() { writer.shutdown() }
}
