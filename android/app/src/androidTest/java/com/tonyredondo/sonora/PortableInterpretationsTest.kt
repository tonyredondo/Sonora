package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PortableInterpretationsTest {
    @Test
    fun learnedAlbumCacheRejectsChangedCorpusBeforeReusingOrExporting() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = "corpus-${UUID.randomUUID()}.sqlite"
        val store = LibraryStore(context, database)
        try {
            val song =
                Song(
                    "one",
                    "file:///one.mp3",
                    "One",
                    "Artist",
                    "Album",
                    lyricsText = "Whole phrase",
                )
            store.saveSongs(listOf(song))
            val input =
                JSONObject()
                    .put(
                        "tracks",
                        org.json
                            .JSONArray()
                            .put(
                                JSONObject()
                                    .put(
                                        "context",
                                        JSONObject()
                                            .put("title", song.title)
                                            .put("artist", song.artist)
                                            .put("album", song.album),
                                    )
                                    .put("genre", song.genre)
                                    .put("lyrics", song.lyricsText),
                            ),
                    )
            PortableInterpretations.remember(
                store,
                song,
                "es",
                true,
                JSONObject()
                    .put("explanation", "Album meaning")
                    .put("model", "gpt-6-astra")
                    .put("effort", "medium"),
                input,
            )
            assertNotNull(PortableInterpretations.load(store, song, "es", true, input))
            assertNotNull(PortableInterpretations.load(store, song, "es", true))
            val changed = JSONObject(input.toString())
            changed.getJSONArray("tracks").getJSONObject(0).put("lyrics", "Different phrase")
            assertNull(PortableInterpretations.load(store, song, "es", true, changed))
            store.saveSongs(listOf(song.copy(lyricsText = "Different phrase")))
            assertNull(PortableInterpretations.load(store, song, "es", true))
            assertFalse(
                PortableInterpretations.export(store, song).containsKey("SONORA_ALBUM_ABOUT:es"),
            )
        } finally {
            store.close()
            context.deleteDatabase(database)
        }
    }

    @Test
    fun mp3MetadataLoadsBothLanguagesOfflineAndRejectsStaleLyrics() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file = File(context.cacheDir, "portable-${UUID.randomUUID()}.mp3")
        val databaseName = "portable-${UUID.randomUUID()}.sqlite"
        val store = LibraryStore(context, databaseName)
        try {
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("replaygain.mp3")
                .use { input -> file.outputStream().use(input::copyTo) }
            var song = LocalAudio(context).read(Uri.fromFile(file))
            val texts =
                mapOf("es" to "Una canción sobre el recuerdo.", "en" to "A song about memory.")
            for ((language, text) in texts) PortableInterpretations.remember(
                store,
                song,
                language,
                false,
                JSONObject()
                    .put("explanation", text)
                    .put("model", "gpt-6-astra")
                    .put("effort", "medium"),
            )
            val tags = PortableInterpretations.export(store, song)
            assertEquals(2, tags.size)
            NativeAudio.writeTags(
                file.absolutePath,
                tags.keys.toTypedArray(),
                tags.values.toTypedArray(),
                null,
            )
            song = LocalAudio(context).read(Uri.fromFile(file))
            assertEquals(
                texts["es"],
                PortableInterpretations.explanation(
                    PortableInterpretations.embedded(song, "es", false)!!,
                ),
            )
            assertEquals(
                texts["en"],
                PortableInterpretations.explanation(
                    PortableInterpretations.embedded(song, "en", false)!!,
                ),
            )
            assertNull(
                PortableInterpretations.embedded(
                    song.copy(lyricsText = "Different lyrics"),
                    "es",
                    false,
                ),
            )
            assertNull(
                PortableInterpretations.embedded(song.copy(title = "Different title"), "es", false),
            )
            assertNull(PortableInterpretations.embedded(song, "fr", false))
        } finally {
            store.close()
            context.deleteDatabase(databaseName)
            file.delete()
        }
    }
}
