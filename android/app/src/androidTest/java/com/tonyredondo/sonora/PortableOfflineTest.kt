package com.tonyredondo.sonora

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PortableOfflineTest {
    @Test
    fun importedSongAndAlbumDescriptionsAppearInBothLanguagesWithoutAnyServer() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val file = File(graph.application.cacheDir, "offline-portable-${UUID.randomUUID()}.mp3")
        val database = "offline-portable-${UUID.randomUUID()}.sqlite"
        val store = LibraryStore(graph.application, database)
        var songId: String? = null
        try {
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("replaygain.mp3")
                .use { input -> file.outputStream().use(input::copyTo) }
            val input =
                graph.reader
                    .read(Uri.fromFile(file))
                    .copy(album = "Offline album ${UUID.randomUUID()}")
            for (language in listOf("es", "en")) for (album in
                listOf(false, true)) PortableInterpretations.remember(
                store,
                input,
                language,
                album,
                JSONObject()
                    .put("explanation", "${if(album)"Album" else "Song"} $language")
                    .put("model", "gpt-6-astra")
                    .put("effort", "medium"),
                JSONObject()
                    .put("tracks", JSONArray().put(JSONObject().put("lyrics", input.lyricsText))),
            )
            val fields = PortableInterpretations.export(store, input).toMutableMap()
            fields["ALBUM"] = arrayOf(input.album)
            NativeAudio.writeTags(
                file.absolutePath,
                fields.keys.toTypedArray(),
                fields.values.toTypedArray(),
                null,
            )
            val song = graph.reader.read(Uri.fromFile(file))
            songId = song.id
            graph.store.saveSongs(listOf(song), inLibrary = false)
            for (language in listOf("es", "en")) {
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    graph.online.value = OnlineSettings(language = language, enabled = false)
                    graph.remote.prepare(listOf(song.id))
                }
                withTimeout(5000) {
                    while (
                        graph.extras.value[song.id]?.meaning != "Song $language" ||
                            graph.extras.value[song.id]?.albumMeaning != "Album $language"
                    ) delay(10)
                }
                assertEquals(
                    PreparationState.READY,
                    graph.extras.value[song.id]!!.progress[PreparationStage.MEANING]!!.state,
                )
                assertEquals(
                    PreparationState.READY,
                    graph.extras.value[song.id]!!.progress[PreparationStage.ALBUM]!!.state,
                )
            }
            assertFalse(graph.store.songs().any { it.id == song.id })
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                graph.online.value = previous
            }
            songId?.let { graph.store.removeSongs(listOf(it)) }
            store.close()
            graph.application.deleteDatabase(database)
            file.delete()
        }
    }
}
