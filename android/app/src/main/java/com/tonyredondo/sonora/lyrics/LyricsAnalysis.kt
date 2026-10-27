package com.tonyredondo.sonora

import java.util.Locale
import kotlin.math.*
import org.json.JSONObject

internal const val transcriptionMarker = "[by:Sonora AI transcription - ElevenLabs]"
internal const val repairMarker = "[by:Sonora AI repair - ElevenLabs]"
internal val lyricControls =
    Regex(
        "\\[(?:\\d{1,3}:\\d{2}|(?:ar|al|ti|au|by|re|ve|length|offset)\\s*:)",
        RegexOption.IGNORE_CASE,
    )

internal fun lyricKey(text: String): String =
    text
        .codePoints()
        .filter { Character.isLetterOrDigit(it) }
        .collect(
            { StringBuilder() },
            { builder, point -> builder.appendCodePoint(point) },
            { a, b -> a.append(b) },
        )
        .toString()
        .lowercase(Locale.ROOT)

/** Validate raw cue order before the ordinary display reader sorts it. */
internal fun validatedTimedLyrics(text: String, duration: Double): LyricsDocument {
    require(
        duration.isFinite() &&
            duration in 1.0..600.0 &&
            text.toByteArray().size <= 65536 &&
            '\u0000' !in text,
    ) {
        "La letra o su duración no es válida para este análisis."
    }
    val document = LyricsDocument.parse(text)
    require(document.lines.isNotEmpty() && document.isTimed) {
        "La respuesta no contiene tiempos completos."
    }
    var previous = -1L
    for (raw in text.lineSequence().map(String::trim).filter(String::isNotEmpty)) {
        val line = LyricsDocument.parse(raw)
        if (line.lines.isEmpty()) continue
        require(line.lines.size == 1 && line.lines.single().timeMs != null) {
            "La respuesta mezcla frases con tiempos y sin tiempos."
        }
        val time = line.lines.single().timeMs!!
        require(time >= previous && time <= duration * 1000 + .01) {
            "La respuesta contiene tiempos fuera de orden o del audio."
        }
        previous = time
    }
    return document
}

internal fun alignedLyrics(synced: String, original: String, duration: Double): String {
    val document = validatedTimedLyrics(synced, duration)
    val lines = original.lineSequence().filter { it.isNotBlank() }.toList()
    require(
        lines.isNotEmpty() &&
            lines.size == document.lines.size &&
            lines.map(::lyricKey) == document.lines.map { lyricKey(it.text) },
    ) {
        "Los tiempos recibidos no corresponden a estas frases."
    }
    var index = 0
    return original.lineSequence().joinToString("\n") { line ->
        if (line.isBlank()) line
        else {
            val time = document.lines[index++].timeMs!! / 10
            "[%02d:%02d.%02d]".format(Locale.ROOT, time / 6000, time / 100 % 60, time % 100) + line
        }
    }
}

data class TranscriptWord(val text: String, val start: Double, val end: Double)

data class LyricsTranscript(
    val plainText: String,
    val syncedText: String,
    val duration: Double,
    val words: List<TranscriptWord>? = null,
) {
    fun validate() {
        require(
            plainText.toByteArray().size <= 65536 &&
                '\u0000' !in plainText &&
                plainText.isNotBlank(),
        ) {
            "La transcripción no contiene una letra válida."
        }
        alignedLyrics(syncedText, plainText, duration)
        words?.let { values ->
            var previous = 0.0
            var bytes = 0
            require(values.isNotEmpty() && values.size <= 65536)
            for (word in values) {
                bytes += word.text.toByteArray().size
                require(
                    bytes <= 262144 &&
                        '\u0000' !in word.text &&
                        lyricKey(word.text).isNotEmpty() &&
                        word.start.isFinite() &&
                        word.end.isFinite() &&
                        word.start >= previous &&
                        word.start >= 0 &&
                        word.start <= duration &&
                        word.end >= word.start &&
                        word.end <= duration + .05,
                ) {
                    "Las palabras recibidas no corresponden a este audio."
                }
                previous = word.start
            }
            require(lyricKey(values.joinToString("") { it.text }) == lyricKey(plainText)) {
                "La transcripción tiene palabras diferentes a sus tiempos."
            }
        }
    }

    companion object {
        fun decode(value: JSONObject, audioHash: String, duration: Double): LyricsTranscript? {
            require(
                listOf("audio_sha256", "model_id", "plain_lyrics", "synced_lyrics").all {
                    value.opt(it) is String
                } && value.opt("duration") is Number,
            )
            require(
                value.getString("audio_sha256") == audioHash &&
                    value.getString("model_id") == "scribe_v2" &&
                    value.getDouble("duration").isFinite() &&
                    abs(value.getDouble("duration") - duration) <= .1,
            ) {
                "El análisis recibido corresponde a otro audio."
            }
            val plain = value.getString("plain_lyrics")
            val synced = value.getString("synced_lyrics")
            val words = value.optJSONArray("words")
            require(!value.has("words") || value.isNull("words") || words != null)
            require(words == null || words.length() <= 65536)
            if (plain.isEmpty() && synced.isEmpty()) {
                require(words == null || words.length() == 0)
                return null
            }
            return LyricsTranscript(
                    plain,
                    synced,
                    duration,
                    words
                        ?.takeIf { it.length() > 0 }
                        ?.let { all ->
                            List(all.length()) { index ->
                                val word = all.getJSONObject(index)
                                require(
                                    word.opt("text") is String &&
                                        word.opt("start") is Number &&
                                        word.opt("end") is Number,
                                )
                                TranscriptWord(
                                    word.getString("text"),
                                    word.getDouble("start"),
                                    word.getDouble("end"),
                                )
                            }
                        },
                )
                .also { it.validate() }
        }
    }
}
