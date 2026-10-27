package com.tonyredondo.sonora

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PortableContractTest {
    private val song =
        Song(
            "id",
            "file:///qa.mp3",
            "Song",
            "Artist",
            "Album",
            lyricsText = "[00:01]A whole phrase\n[00:02]Last phrase",
        )

    private fun record(language: String = "es") =
        JSONObject()
            .put("version", 1)
            .put("language", language)
            .put("title", song.title)
            .put("artist", song.artist)
            .put("album", song.album)
            .put("lyricsDigest", contentDigest("A whole phrase\nLast phrase"))
            .put(
                "interpretation",
                JSONObject()
                    .put("explanation", "Sobre el recuerdo.")
                    .put("model", "gpt-6-astra")
                    .put("effort", "medium"),
            )

    private fun tagged(fields: Map<String, JSONObject>) =
        song.copy(
            metadata =
                JSONObject()
                    .put(
                        "native_custom",
                        JSONObject().apply {
                            for ((key, value) in fields) put(key, JSONArray().put(value.toString()))
                        },
                    )
                    .toString(),
        )

    @Test
    fun languageKeysCoexistAndIgnoreTimingEdits() {
        val item =
            tagged(
                mapOf("SONORA_SONG_ABOUT:es" to record(), "SONORA_SONG_ABOUT:en" to record("en")),
            )
        assertNotNull(PortableInterpretations.embedded(item, "es", false))
        assertNotNull(PortableInterpretations.embedded(item, "en", false))
        assertNull(PortableInterpretations.embedded(item, "fr", false))
        assertNotNull(
            PortableInterpretations.embedded(
                item.copy(lyricsText = "[00:04]A whole phrase\n[00:09]Last phrase"),
                "es",
                false,
            ),
        )
        assertNull(
            PortableInterpretations.embedded(
                item.copy(lyricsText = "Different phrase"),
                "es",
                false,
            ),
        )
    }

    @Test
    fun canonicalLanguageKeyWinsOverLegacyEvenWhenCanonicalIsInvalid() {
        val item =
            tagged(mapOf("SONORA_SONG_ABOUT" to record(), "SONORA_SONG_ABOUT:es" to record("en")))
        assertNull(PortableInterpretations.embedded(item, "es", false))
        assertNotNull(
            PortableInterpretations.embedded(
                tagged(mapOf("SONORA_SONG_ABOUT" to record())),
                "es",
                false,
            ),
        )
    }

    @Test
    fun invalidOrStalePayloadsAreRejected() {
        for (value in
            listOf(
                record().put("version", 2),
                record().put("version", 1.5),
                record().put("version", "1"),
                record().put("title", "Other song"),
                record().put("lyricsDigest", "abc"),
                record().apply { getJSONObject("interpretation").put("model", "other") },
                record().apply {
                    getJSONObject("interpretation").put("explanation", "Bad\u007ftext")
                },
                record().apply { getJSONObject("interpretation").put("explanation", 123) },
            )) assertNull(
            PortableInterpretations.embedded(
                tagged(mapOf("SONORA_SONG_ABOUT:es" to value)),
                "es",
                false,
            ),
        )
    }

    @Test
    fun albumRecordRequiresACompleteValidCorpusCount() {
        val album = record().put("title", song.album).put("trackCount", 2).put("missingLyrics", 1)
        val item = tagged(mapOf("SONORA_ALBUM_ABOUT:es" to album))
        assertNotNull(PortableInterpretations.embedded(item, "es", true))
        for (count in listOf(-1, 2, 3, "1", 1.5)) assertNull(
            PortableInterpretations.embedded(
                tagged(
                    mapOf(
                        "SONORA_ALBUM_ABOUT:es" to
                            JSONObject(album.toString()).put("missingLyrics", count),
                    ),
                ),
                "es",
                true,
            ),
        )
    }
}
