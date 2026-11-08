package com.oleg.dualscreen

import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory

/** JVM fixture reading the real Android XML catalog; never a duplicate translation table. */
internal class ResourceTestStrings(qualifier: String) : UiStrings {
    private val locale = if (qualifier == "values-ru") Locale("ru") else Locale.ENGLISH
    private val values: Map<Int, String>
    init {
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$qualifier/strings.xml")).getElementsByTagName("string")
        values = (0 until nodes.length).associate { index ->
            val node = nodes.item(index)
            val id = R.string::class.java.getField(node.attributes.getNamedItem("name").nodeValue).getInt(null)
            id to node.textContent.removeSurrounding("\"").replace("\\n", "\n").replace("\\'", "'").replace("\\\"", "\"")
        }
    }
    override fun get(id: Int, vararg args: Any): String = String.format(locale, values.getValue(id), *args)
}
