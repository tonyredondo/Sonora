package com.tonyredondo.sonora

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

data class LyricsDraft(val lines: List<LyricLine>, val headers: List<String>) {
    fun clearTiming(): LyricsDraft = copy(lines = lines.map { it.copy(timeMs = null) })

    fun mark(index: Int, millis: Long): LyricsDraft {
        require(index in lines.indices && millis in 0..59_999_990) {
            "El tiempo de la frase no es válido."
        }
        val time = (millis + 5) / 10 * 10
        val previous = lines.take(index).mapNotNull { it.timeMs }.lastOrNull()
        val next = lines.drop(index + 1).mapNotNull { it.timeMs }.firstOrNull()
        require((previous == null || time >= previous) && (next == null || time <= next)) {
            "El tiempo debe quedar entre las frases anterior y siguiente."
        }
        return copy(
            lines =
                lines.mapIndexed { i, line -> if (i == index) line.copy(timeMs = time) else line },
        )
    }

    fun serialize(): String {
        val count = lines.count { it.timeMs != null }
        require(count == 0 || count == lines.size) {
            "Marca todas las frases o elimina los tiempos antes de guardar."
        }
        val times = lines.mapNotNull { it.timeMs }
        require(times.zipWithNext().all { (a, b) -> a <= b }) {
            "Los tiempos de las frases deben estar en orden."
        }
        return (headers +
                lines.map { line -> (line.timeMs?.let(::lyricTimestamp) ?: "") + line.text })
            .joinToString("\n")
    }

    companion object {
        fun from(text: String): LyricsDraft {
            val document = LyricsDocument.parse(text)
            return LyricsDraft(document.editableLines, document.headers)
        }
    }
}

fun lyricTimestamp(millis: Long): String {
    require(millis in 0..59_999_990)
    return String.format(
        Locale.ROOT,
        "[%02d:%02d.%02d]",
        millis / 60000,
        (millis % 60000) / 1000,
        (millis % 1000) / 10,
    )
}

data class LoopRegion(val songId: String, val startMs: Long, val endMs: Long) {
    fun validate() {
        require(songId.isNotBlank() && startMs >= 0 && endMs - startMs >= 100) {
            "El fragmento no tiene una duración válida."
        }
    }
}

fun phraseLoop(
    id: String,
    document: LyricsDocument,
    index: Int,
    durationMs: Long,
    offsetMs: Long,
): LoopRegion {
    require(index in document.lines.indices && offsetMs in -5000..5000)
    val source =
        requireNotNull(document.lines[index].timeMs) { "La frase no tiene un tiempo asignado." }
    val next = document.lines.drop(index + 1).mapNotNull { it.timeMs }.firstOrNull { it > source }
    val start = (source + offsetMs).coerceAtLeast(0)
    val end = next?.let { (it + offsetMs).coerceAtMost(durationMs) } ?: durationMs
    return LoopRegion(id, start, end).also { it.validate() }
}

data class SongMarker(val id: String, val title: String, val positionMs: Long)

data class SongTools(val offsetMs: Long = 0, val markers: List<SongMarker> = emptyList()) {
    fun validate() {
        require(offsetMs in -5000..5000 && markers.size <= 1000) {
            "El ajuste de tiempos no es válido."
        }
        require(markers.map { it.id }.distinct().size == markers.size)
        require(
            markers.all {
                it.id.isNotBlank() &&
                    it.id.length <= 100 &&
                    it.title.isNotBlank() &&
                    it.title.toByteArray().size <= 200 &&
                    it.title.none(Char::isISOControl) &&
                    it.positionMs in 0..86_400_000
            },
        ) {
            "El marcador no es válido."
        }
    }

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("offset", offsetMs)
            .put(
                "markers",
                JSONArray(
                    markers.map {
                        JSONObject()
                            .put("id", it.id)
                            .put("title", it.title)
                            .put("position", it.positionMs)
                    },
                ),
            )
            .toString()
    }

    companion object {
        fun decode(text: String): SongTools {
            require(text.toByteArray().size <= 512000)
            val value = JSONObject(text)
            require(value.opt("version") == 1)
            val markers = value.getJSONArray("markers")
            require(markers.length() <= 1000)
            return SongTools(
                    value.getLong("offset"),
                    (0 until markers.length()).map { i ->
                        markers.getJSONObject(i).let {
                            SongMarker(
                                it.getString("id"),
                                it.getString("title"),
                                it.getLong("position"),
                            )
                        }
                    },
                )
                .also { it.validate() }
        }
    }
}
