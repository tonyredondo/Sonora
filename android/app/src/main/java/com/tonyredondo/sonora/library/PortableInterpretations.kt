package com.tonyredondo.sonora

import org.json.JSONArray
import org.json.JSONObject

/** Shared v1 ID3 contract with iPhone. Only completed, identity-matched content is portable. */
object PortableInterpretations {
    val languages = setOf("es", "en", "fr", "de", "it", "pt")
    private const val songPrefix = "SONORA_SONG_ABOUT"
    private const val albumPrefix = "SONORA_ALBUM_ABOUT"

    private fun safe(value: String, limit: Int, multiline: Boolean = false): Boolean =
        value.toByteArray().size <= limit &&
            value.none { it.isISOControl() && (!multiline || it !in "\t\r\n") }

    private fun valid(record: JSONObject, song: Song, language: String, album: Boolean): Boolean {
        if (record.opt("version") !is Number || record.opt("language") !is String) return false
        if (listOf("title", "artist").any { record.opt(it) !is String }) return false
        if (
            language !in languages ||
                record.optDouble("version") != 1.0 ||
                record.optString("language") != language
        )
            return false
        for (key in listOf("title", "artist")) if (!safe(record.optString(key), 4096)) return false
        val content = record.optJSONObject("interpretation") ?: return false
        if (listOf("explanation", "model", "effort").any { content.opt(it) !is String })
            return false
        val text = content.optString("explanation")
        if (
            content.optString("model") != "gpt-6-astra" ||
                content.optString("effort") !in setOf("medium", "xhigh") ||
                text.isBlank() ||
                !safe(text, 32768, true)
        )
            return false
        return if (album) {
            if (
                listOf("trackCount", "missingLyrics").any {
                    record.opt(it) !is Number ||
                        record.getDouble(it) != record.getInt(it).toDouble()
                }
            )
                return false
            val tracks = record.optInt("trackCount")
            val missing = record.optInt("missingLyrics", -1)
            record.optString("title").isNotBlank() &&
                record.getString("title").trim() == song.album.trim() &&
                record.getString("artist").trim() == albumArtist(song).trim() &&
                tracks in 1..100 &&
                missing in 0 until tracks
        } else {
            record.optString("title") == song.title &&
                record.optString("artist") == song.artist &&
                record.optString("album") == song.album &&
                safe(record.optString("album"), 4096) &&
                record.optString("lyricsDigest") ==
                    contentDigest(LyricsDocument.parse(song.lyricsText).plainText)
        }
    }

    private fun albumArtist(song: Song): String =
        try {
            JSONObject(song.metadata)
                .optJSONObject("native_fields")
                ?.optJSONArray("ALBUMARTIST")
                ?.optString(0)
                ?.takeIf(String::isNotBlank) ?: song.artist
        } catch (_: Exception) {
            song.artist
        }

    private fun cacheKey(song: Song, language: String, album: Boolean): String =
        "portable:v1:${if(album) "album" else "song"}:$language:" +
            contentDigest(
                if (album) "${song.album.trim()}\u0000${albumArtist(song).trim()}"
                else
                    "${song.title}\u0000${song.artist}\u0000${song.album}\u0000${contentDigest(LyricsDocument.parse(song.lyricsText).plainText)}",
            )

    fun embedded(song: Song, language: String, album: Boolean): JSONObject? {
        return try {
            val custom = JSONObject(song.metadata).optJSONObject("native_custom") ?: return null
            val prefix = if (album) albumPrefix else songPrefix
            val key = if (custom.has("$prefix:$language")) "$prefix:$language" else prefix
            val values = custom.optJSONArray(key) ?: return null
            if (values.length() != 1) return null
            val raw = values.opt(0) as? String ?: return null
            if (raw.toByteArray().size > 131072) return null
            JSONObject(raw).takeIf { valid(it, song, language, album) }
        } catch (_: Exception) {
            null
        }
    }

    private fun corpusSignature(input: JSONObject): String? =
        try {
            val tracks = input.getJSONArray("tracks")
            contentDigest(
                JSONArray()
                    .apply {
                        for (index in 0 until tracks.length()) {
                            val track = tracks.getJSONObject(index)
                            val context = track.getJSONObject("context")
                            put(
                                JSONArray(
                                    listOf(
                                        context.getString("title"),
                                        context.getString("artist"),
                                        context.getString("album"),
                                        track.optString("genre"),
                                        track.getString("lyrics"),
                                    ),
                                ),
                            )
                        }
                    }
                    .toString(),
            )
        } catch (_: Exception) {
            null
        }

    private fun localCorpusSignature(songs: List<Song>): String =
        contentDigest(
            JSONArray(
                    songs
                        .sortedWith(
                            compareBy<Song> {
                                    if (it.trackNumber > 0) it.trackNumber else Int.MAX_VALUE
                                }
                                .thenComparator { a, b -> compareNatural(a.title, b.title) },
                        )
                        .map {
                            JSONArray(
                                listOf(
                                    it.title,
                                    it.artist,
                                    it.album,
                                    it.genre,
                                    LyricsDocument.parse(it.lyricsText).plainText,
                                ),
                            )
                        },
                )
                .toString(),
        )

    fun load(
        store: LibraryStore,
        song: Song,
        language: String,
        album: Boolean,
        albumInput: JSONObject? = null,
    ): JSONObject? {
        val cached =
            try {
                val stored = store.state(cacheKey(song, language, album))?.let(::JSONObject)
                val record = if (album) stored?.optJSONObject("record") else stored
                var matches = true
                if (album && stored != null) {
                    if (albumInput != null)
                        matches =
                            stored.optString("corpusDigest") == contentDigest(albumInput.toString())
                    else {
                        val known = store.albumSongs(song.artist, song.album)
                        if (known.isNotEmpty())
                            matches =
                                stored.optString("corpusSignature") == localCorpusSignature(known)
                    }
                }
                record?.takeIf { matches && valid(it, song, language, album) }
            } catch (_: Exception) {
                null
            }
        return cached ?: embedded(song, language, album)
    }

    fun remember(
        store: LibraryStore,
        song: Song,
        language: String,
        album: Boolean,
        value: JSONObject,
        albumInput: JSONObject? = null,
    ) {
        val record =
            JSONObject()
                .put("version", 1)
                .put("language", language)
                .put("title", if (album) song.album else song.title)
                .put("artist", if (album) albumArtist(song) else song.artist)
                .put("interpretation", value)
        if (album) {
            val tracks = albumInput?.optJSONArray("tracks") ?: return
            record
                .put("trackCount", tracks.length())
                .put(
                    "missingLyrics",
                    (0 until tracks.length()).count {
                        tracks.getJSONObject(it).optString("lyrics").isBlank()
                    },
                )
        } else
            record
                .put("album", song.album)
                .put("lyricsDigest", contentDigest(LyricsDocument.parse(song.lyricsText).plainText))
        if (valid(record, song, language, album)) {
            val stored =
                if (album)
                    JSONObject()
                        .put("record", record)
                        .put("corpusDigest", contentDigest(requireNotNull(albumInput).toString()))
                        .put("corpusSignature", corpusSignature(albumInput))
                else record
            store.putState(cacheKey(song, language, album), stored.toString())
        }
    }

    fun export(store: LibraryStore, song: Song): Map<String, Array<String>> = buildMap {
        for (language in languages) for (album in listOf(false, true)) load(
                store,
                song,
                language,
                album,
            )
            ?.let {
                put("${if(album)albumPrefix else songPrefix}:$language", arrayOf(it.toString()))
            }
    }

    fun explanation(record: JSONObject): String =
        record.getJSONObject("interpretation").getString("explanation")
}
