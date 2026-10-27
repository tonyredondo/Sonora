package com.tonyredondo.sonora

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Host-driven chooser proof uses only this disposable fixture on the owned emulator. */
class ExportUiFixtureTest {
    @Test
    fun arrangeOrRemoveOwnedFixture() = runBlocking {
        val mode = InstrumentationRegistry.getArguments().getString("exportUi")
        assumeTrue(mode == "seed" || mode == "cleanup")
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val key = "export-ui-qa-v1"
        if (mode == "seed") {
            check(graph.store.state(key) in listOf(null, "null")) {
                "An existing fixture must be recovered first."
            }
            val file = File(graph.application.filesDir, "export-ui-${UUID.randomUUID()}.mp3")
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("replaygain.mp3")
                .use { input -> file.outputStream().use(input::copyTo) }
            val song = graph.reader.read(Uri.fromFile(file)).copy(title = "Export QA")
            graph.store.saveSongs(listOf(song))
            val list = graph.store.createPlaylist("Export QA")
            graph.store.setPlaylistSongs(list, listOf(song.id))
            graph.store.putState(
                key,
                JSONObject()
                    .put("song", song.id)
                    .put("playlist", list)
                    .put("path", file.absolutePath)
                    .toString(),
            )
        } else {
            graph.store
                .state(key)
                ?.takeUnless { it == "null" }
                ?.let(::JSONObject)
                ?.let { fixture ->
                    val file = File(fixture.getString("path"))
                    check(
                        file.parentFile == graph.application.filesDir &&
                            file.name.startsWith("export-ui-"),
                    )
                    graph.store.removePlaylist(fixture.getString("playlist"))
                    graph.store.removeSongs(listOf(fixture.getString("song")))
                    check(file.delete())
                    graph.store.putState(key, "null")
                }
        }
        graph.refresh()
    }
}
