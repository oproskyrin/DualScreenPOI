package com.oleg.dualscreen

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory

/** Reads the shipped resources, not a second dictionary or mocked Android Resources. */
class LocalizationResourcesTest {
    private fun strings(qualifier: String): Map<String, String> {
        val file = File("src/main/res/$qualifier/strings.xml")
        assertTrue("Missing $file", file.isFile)
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).getElementsByTagName("string")
        val result = linkedMapOf<String, String>()
        for (i in 0 until nodes.length) {
            val node = nodes.item(i)
            val name = node.attributes.getNamedItem("name").nodeValue
            assertNull("Duplicate resource: $name", result.put(name, node.textContent))
        }
        return result
    }
    @Test fun productionKotlinHasNoEmbeddedRussianUiText() {
        File("src/main/java").walkTopDown().filter { it.extension == "kt" }.forEach { file ->
            val source = file.readText().replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
                .replace(Regex("(?m)//.*$"), "")
            assertFalse("Move UI strings to resources: $file", Regex("[А-Яа-яЁё]").containsMatchIn(source))
        }
    }

    private val placeholder = Regex("%(?:(\\d+)\\$)?[-#+ 0,(]*\\d*(?:\\.\\d+)?([a-zA-Z%])")
    @Test fun explicitEnglishHasEveryFallbackStringEvenWhenRussianIsASecondarySystemLocale() {
        // Android's locale-list matching may otherwise select values-ru for [en, ru].
        // Explicit en resources keep the manual English override deterministic.
        assertEquals(strings("values"), strings("values-en"))
    }

    @Test fun englishFallbackAndRussianHaveIdenticalKeysAndFormatContracts() {
        val en = strings("values")
        val ru = strings("values-ru")
        assertTrue("Complete UI resource catalog", en.size > 100)
        assertEquals(en.keys, ru.keys)
        for ((key, value) in en) {
            fun signature(s: String) = placeholder.findAll(s).filter { it.groupValues[2] != "%" }
                .map { it.groupValues[1] + ":" + it.groupValues[2] }.sorted().toList()
            assertEquals("Placeholder mismatch: $key", signature(value), signature(ru.getValue(key)))
            assertFalse("Russian in English fallback: $key", Regex("[А-Яа-яЁё]").containsMatchIn(value) && key != "language_russian")
            for (text in listOf(value, ru.getValue(key))) {
                assertFalse("Malformed placeholder: $key", placeholder.replace(text, "").contains('%'))
                val matches = placeholder.findAll(text).filter { it.groupValues[2] != "%" }.toList()
                assertTrue("Use indexed arguments: $key", matches.all { it.groupValues[1].isNotEmpty() })
                if (matches.isNotEmpty()) {
                    val args = arrayOfNulls<Any>(matches.maxOf { it.groupValues[1].toInt() })
                    matches.forEach { m -> args[m.groupValues[1].toInt() - 1] = when (m.groupValues[2]) { "d" -> 42; "f" -> 12.5; else -> "sample" } }
                    String.format(Locale.US, text, *args)
                    String.format(Locale("ru"), text, *args)
                }
            }
        }
    }
}
