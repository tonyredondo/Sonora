package com.tonyredondo.sonora

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.json.JSONObject

/** CUE positions use 75 CD frames per second, independent of the PCM sampling rate. */
data class CueSegment(
    val sheetUri: String,
    val number: Int,
    val startCDFrame: Int,
    val endCDFrame: Int?,
    val sheetRevision: String = "",
) {
    init {
        require(sheetUri.isNotBlank() && number in 1..999 && startCDFrame in 0 until 450_000_000)
        require(endCDFrame == null || (endCDFrame > startCDFrame && endCDFrame < 450_000_000))
        require(sheetRevision.isEmpty() || sheetRevision.matches(Regex("[0-9a-f]{64}")))
    }

    val startUs: Long
        get() = (startCDFrame.toLong() * 1_000_000 + 37) / 75

    val endUs: Long?
        get() = endCDFrame?.let { (it.toLong() * 1_000_000 + 37) / 75 }

    fun startFrame(rate: Int): Long = (startCDFrame.toLong() * rate + 37) / 75

    fun endFrame(rate: Int, totalFrames: Long): Long =
        endCDFrame?.let { (it.toLong() * rate + 37) / 75 } ?: totalFrames

    fun applyTo(base: Song): Song {
        val end = endUs ?: (base.durationMs * 1000)
        require(end > startUs && (base.durationMs == 0L || end <= base.durationMs * 1000 + 1000)) {
            "La pista CUE queda fuera del archivo de audio."
        }
        val metadata =
            JSONObject(base.metadata)
                .put(
                    "cue",
                    JSONObject()
                        .put("sheet", sheetUri)
                        .put("number", number)
                        .put("start", startCDFrame)
                        .put("revision", sheetRevision)
                        .put("end", endCDFrame),
                )
        // Track loudness/portable text of a complete disc does not describe this interval.
        metadata.remove("replaygain_track_gain")
        metadata.remove("replaygain_track_peak")
        for (kind in listOf("native_fields", "native_custom")) metadata.optJSONObject(kind)?.let {
            fields ->
            fields
                .keys()
                .asSequence()
                .toList()
                .filter {
                    it.startsWith("SONORA_", true) || it.startsWith("REPLAYGAIN_TRACK_", true)
                }
                .forEach(fields::remove)
        }
        val document = LyricsDocument.parse(base.lyricsText)
        val lyrics =
            if (!document.isTimed) base.lyricsText
            else
                buildString {
                    document.headers.forEach { append(it).append('\n') }
                    document.lines
                        .filter {
                            it.timeMs != null &&
                                it.timeMs * 1000 >= startUs &&
                                it.timeMs * 1000 < end
                        }
                        .forEach {
                            val time =
                                ((it.timeMs!! * 1000 - startUs + 500) / 1000).coerceAtLeast(0)
                            append(
                                "[%02d:%02d.%03d]%s\n"
                                    .format(
                                        java.util.Locale.ROOT,
                                        time / 60000,
                                        time / 1000 % 60,
                                        time % 1000,
                                        it.text,
                                    ),
                            )
                        }
                }
                    .trimEnd()
        return base.copy(
            id = contentDigest("${base.uri}|cue:$sheetUri|$number"),
            durationMs = (end - startUs + 500) / 1000,
            trackNumber = number,
            lyricsText = lyrics,
            metadata = metadata.toString(),
        )
    }
}

/** A present but damaged segment must fail, never silently play/export the entire source. */
fun Song.cueSegment(): CueSegment? {
    val objectValue = JSONObject(metadata)
    if (!objectValue.has("cue")) return null
    val cue = objectValue.getJSONObject("cue")
    fun integer(key: String): Int {
        require(cue.opt(key) is Number && cue.getDouble(key) == cue.getInt(key).toDouble()) {
            "Los límites CUE guardados no son válidos."
        }
        return cue.getInt(key)
    }
    return CueSegment(
        cue.getString("sheet"),
        integer("number"),
        integer("start"),
        if (cue.isNull("end")) null else integer("end"),
        cue.optString("revision"),
    )
}

fun Song.cueSourceSuffix(): String =
    cueSegment()?.let { "|cue:${it.startCDFrame}:${it.endCDFrame}" }.orEmpty()

data class CueSheetTrack(
    val path: String,
    val number: Int,
    val startCDFrame: Int,
    val endCDFrame: Int?,
    val title: String,
    val artist: String,
    val album: String,
    val genre: String,
    val composer: String = "",
    val date: String = "",
    val disc: String = "",
    val albumArtist: String = "",
) {
    fun song(base: Song, sheetUri: String, sheetRevision: String = ""): Song {
        val song =
            CueSegment(sheetUri, number, startCDFrame, endCDFrame, sheetRevision).applyTo(base)
        val metadata = JSONObject(song.metadata)
        val fields =
            metadata.optJSONObject("native_fields")
                ?: JSONObject().also { metadata.put("native_fields", it) }
        for ((key, value) in
            mapOf(
                "COMPOSER" to composer,
                "DATE" to date,
                "DISCNUMBER" to disc,
                "ALBUMARTIST" to albumArtist,
            )) if (value.isNotBlank()) fields.put(key, org.json.JSONArray().put(value))
        return song.copy(
            title = title,
            artist = artist.ifBlank { base.artist },
            album = album.ifBlank { base.album },
            genre = genre.ifBlank { base.genre },
            metadata = metadata.toString(),
        )
    }
}

object CueSheet {
    fun parse(
        bytes: ByteArray,
        sheetPath: String,
        availablePaths: Set<String>,
    ): List<CueSheetTrack> {
        require(bytes.size in 1..2_097_152) { "El archivo CUE está vacío o es demasiado grande." }
        val text =
            when {
                bytes.size >= 2 && bytes[0] == (-1).toByte() && bytes[1] == (-2).toByte() ->
                    bytes.copyOfRange(2, bytes.size).toString(Charsets.UTF_16LE)
                bytes.size >= 2 && bytes[0] == (-2).toByte() && bytes[1] == (-1).toByte() ->
                    bytes.copyOfRange(2, bytes.size).toString(Charsets.UTF_16BE)
                else ->
                    try {
                        Charsets.UTF_8.newDecoder()
                            .onMalformedInput(CodingErrorAction.REPORT)
                            .decode(ByteBuffer.wrap(bytes))
                            .toString()
                    } catch (_: java.nio.charset.CharacterCodingException) {
                        bytes.toString(java.nio.charset.Charset.forName("windows-1252"))
                    }
            }.removePrefix("\uFEFF")
        require('\u0000' !in text) { "El archivo CUE contiene texto inválido." }
        data class Draft(
            val path: String,
            val number: Int,
            var start: Int? = null,
            val tags: MutableMap<String, String> = mutableMapOf(),
        )
        val album = mutableMapOf<String, String>()
        val tracks = mutableListOf<Draft>()
        var file: String? = null
        var current: Draft? = null
        fun time(value: String): Int {
            val parts = value.split(':').map { it.toIntOrNull() ?: error("Tiempo CUE inválido.") }
            require(
                parts.size == 3 &&
                    parts[0] in 0 until 100000 &&
                    parts[1] in 0..59 &&
                    parts[2] in 0..74,
            ) {
                "Tiempo CUE inválido."
            }
            return parts[0] * 4500 + parts[1] * 75 + parts[2]
        }
        for (line in text.lineSequence()) {
            val tokens = tokenize(line)
            if (tokens.isEmpty()) continue
            val command = tokens[0].uppercase(java.util.Locale.ROOT)
            val values = tokens.drop(1)
            when (command) {
                "FILE" -> {
                    require(values.size == 2)
                    val path = values[0].replace('\\', '/')
                    require(!path.startsWith('/') && ':' !in path && path.isNotBlank()) {
                        "La ruta CUE no es relativa a la carpeta elegida."
                    }
                    val components = sheetPath.split('/').dropLast(1).toMutableList()
                    for (part in path.split('/')) when (part) {
                        "",
                        "." -> Unit
                        ".." -> {
                            require(components.isNotEmpty()) {
                                "La ruta CUE sale de la carpeta elegida."
                            }
                            components.removeAt(components.lastIndex)
                        }
                        else -> components.add(part)
                    }
                    file = components.joinToString("/")
                    require(file in availablePaths) { "No se encontró el audio CUE: $file" }
                    current = null
                }
                "TRACK" -> {
                    require(values.size == 2 && values[1].equals("AUDIO", true)) {
                        "Solo se admiten pistas CUE de audio."
                    }
                    val number = values[0].toIntOrNull() ?: error("Número CUE inválido.")
                    require(
                        number in 1..999 &&
                            tracks.size < 999 &&
                            number > (tracks.lastOrNull()?.number ?: 0),
                    )
                    current =
                        Draft(requireNotNull(file) { "Falta FILE en el CUE." }, number)
                            .also(tracks::add)
                }
                "INDEX" -> {
                    require(values.size == 2)
                    val draft = requireNotNull(current)
                    require(values[0].toIntOrNull() in 0..99)
                    val position = time(values[1])
                    if (values[0].toInt() == 1) {
                        require(draft.start == null) { "INDEX 01 está repetido." }
                        draft.start = position
                    }
                }
                "TITLE",
                "PERFORMER",
                "SONGWRITER" -> {
                    require(values.size == 1)
                    (current?.tags ?: album)[command] = values[0]
                }
                "REM" ->
                    if (
                        values.size >= 2 &&
                            values[0].uppercase() in setOf("DATE", "GENRE", "DISCNUMBER")
                    )
                        album[values[0].uppercase()] = values.drop(1).joinToString(" ")
                "PREGAP",
                "POSTGAP" ->
                    require(values.size == 1 && time(values[0]) == 0) {
                        "Este CUE añade silencio sintético que aún no se puede reproducir."
                    }
            }
        }
        require(tracks.isNotEmpty()) { "El archivo CUE no contiene pistas." }
        val closed = mutableSetOf<String>()
        var previous: Draft? = null
        return tracks.mapIndexed { index, track ->
            val start =
                requireNotNull(track.start) { "Falta INDEX 01 en la pista ${track.number}." }
            previous?.let { old ->
                if (old.path == track.path)
                    require(start > old.start!!) { "Los tiempos CUE no están ordenados." }
                else {
                    closed.add(old.path)
                    require(track.path !in closed) { "El CUE vuelve a un archivo anterior." }
                }
            }
            previous = track
            val tags = album + track.tags
            CueSheetTrack(
                track.path,
                track.number,
                start,
                tracks.getOrNull(index + 1)?.takeIf { it.path == track.path }?.start,
                track.tags["TITLE"] ?: "Pista ${track.number}",
                tags["PERFORMER"].orEmpty(),
                album["TITLE"].orEmpty(),
                album["GENRE"].orEmpty(),
                tags["SONGWRITER"].orEmpty(),
                album["DATE"].orEmpty(),
                album["DISCNUMBER"].orEmpty(),
                album["PERFORMER"].orEmpty(),
            )
        }
    }

    private fun tokenize(line: String): List<String> {
        val values = mutableListOf<String>()
        val token = StringBuilder()
        var quoted = false
        var active = false
        for (char in line) when {
            char == '"' -> {
                quoted = !quoted
                active = true
            }
            char.isWhitespace() && !quoted -> {
                if (active) {
                    values.add(token.toString())
                    token.clear()
                    active = false
                }
            }
            else -> {
                token.append(char)
                active = true
            }
        }
        require(!quoted) { "Comillas sin cerrar en el archivo CUE." }
        if (active) values.add(token.toString())
        return values
    }
}
