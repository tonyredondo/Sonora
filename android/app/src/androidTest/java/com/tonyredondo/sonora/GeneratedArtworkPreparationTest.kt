package com.tonyredondo.sonora

import android.graphics.Bitmap
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class GeneratedArtworkPreparationTest {
    @Test
    fun artworkMetadataAppearsInMediaSessionWithoutInterruptingPlayback() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val id = "art-session-${UUID.randomUUID()}"
        val audio = File(app.cacheDir, "$id.wav")
        val cover = File(app.cacheDir, "$id.png")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            audio.outputStream().use(input::copyTo)
        }
        cover.outputStream().use { output ->
            Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
                .compress(Bitmap.CompressFormat.PNG, 100, output)
        }
        val digest = contentDigest(audio.readBytes())
        val song =
            Song(
                id,
                android.net.Uri.fromFile(audio).toString(),
                "Artwork session QA",
                durationMs = 30000,
            )
        graph.store.saveSongs(listOf(song), inLibrary = false)
        fun main(action: () -> Unit) =
            InstrumentationRegistry.getInstrumentation().runOnMainSync(action)
        lateinit var future:
            com.google.common.util.concurrent.ListenableFuture<
                androidx.media3.session.MediaController,
            >
        main {
            future =
                androidx.media3.session.MediaController.Builder(
                        app,
                        androidx.media3.session.SessionToken(
                            app,
                            android.content.ComponentName(app, PlaybackService::class.java),
                        ),
                    )
                    .setApplicationLooper(android.os.Looper.getMainLooper())
                    .buildAsync()
        }
        val controller = future.get(10, java.util.concurrent.TimeUnit.SECONDS)
        suspend fun until(predicate: () -> Boolean) =
            withTimeout(10000) {
                while (true) {
                    var valid = false
                    main { valid = predicate() }
                    if (valid) break
                    delay(20)
                }
            }
        try {
            main {
                controller.setMediaItem(song.mediaItem())
                controller.prepare()
                controller.play()
            }
            until { controller.isPlaying && controller.currentPosition > 250 }
            var position = 0L
            main { position = controller.currentPosition }
            graph.store.setGeneratedArtwork(id, cover.path, "synthetic-artwork-binding")
            graph.refresh()
            until {
                controller.mediaMetadata.artworkUri?.path == cover.path &&
                    controller.isPlaying &&
                    controller.currentPosition > position + 100
            }
            main {
                assertNull(controller.playerError)
                assertEquals("Artwork session QA", controller.mediaMetadata.title.toString())
            }
            assertEquals(digest, contentDigest(audio.readBytes()))
        } finally {
            main {
                controller.pause()
                controller.clearMediaItems()
                androidx.media3.session.MediaController.releaseFuture(future)
            }
            graph.store.removeSongs(listOf(id))
            audio.delete()
            cover.delete()
        }
    }

    @Test
    fun generatedCoverUsesAlbumGenreAndTagsAndKeepsOpenWithOutsideTheLibrary() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val old = graph.online.value
        val id = "generated-qa-${UUID.randomUUID()}"
        val ids = listOf(id, "$id-copy")
        val before = graph.store.songs().map { it.id }
        val bytes =
            ByteArrayOutputStream().use { output ->
                Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
                    .apply { eraseColor(0xff886644.toInt()) }
                    .compress(Bitmap.CompressFormat.PNG, 100, output)
                output.toByteArray()
            }
        val calls = AtomicInteger()
        val server = MockWebServer()
        val job = "b".repeat(64)
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.path?.contains("expansions") == true)
                        return MockResponse()
                            .setResponseCode(503)
                            .setBody("{\"error\":\"codex_disabled\"}")
                    return when {
                        request.path?.endsWith("/image") == true ->
                            MockResponse()
                                .setHeader("Content-Type", "image/png")
                                .setBody(Buffer().write(bytes))
                        request.method == "POST" -> {
                            calls.incrementAndGet()
                            val input = JSONObject(request.body.readUtf8())
                            assertEquals("Rock", input.getString("genre"))
                            assertEquals(
                                "Un álbum sobre el cambio.",
                                input.getString("album_description"),
                            )
                            assertEquals(
                                "Rock---Alternative Rock",
                                input.getJSONArray("styles").getString(0),
                            )
                            assertEquals("QA Album", input.getString("album"))
                            assertEquals("QA Artist", input.getString("artist"))
                            MockResponse()
                                .setResponseCode(202)
                                .setBody("{\"id\":\"$job\",\"state\":\"queued\"}")
                        }
                        else -> MockResponse().setBody("{\"id\":\"$job\",\"state\":\"completed\"}")
                    }
                }
            }
        server.start()
        val endpoint = server.url("/").toString()
        val owned = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        try {
            graph.store.saveSongs(
                ids.map { target ->
                    Song(
                        target,
                        "content://generated-qa/$target",
                        "QA Song $id",
                        "QA Artist",
                        "QA Album",
                        genre = "Rock",
                    )
                },
                inLibrary = false,
            )
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                graph.online.value = OnlineSettings(endpoint)
                graph.extras.value =
                    graph.extras.value +
                        (id to
                            SongExtras(
                                albumMeaning = "Un álbum sobre el cambio.",
                                styles = listOf("Rock---Alternative Rock"),
                                moods = listOf("sad"),
                                progress =
                                    mapOf(
                                        PreparationStage.TAGS to
                                            PreparationProgress(PreparationState.READY),
                                        PreparationStage.ALBUM to
                                            PreparationProgress(PreparationState.READY),
                                    ),
                            ))
                graph.extras.value = graph.extras.value + (ids[1] to graph.extras.value[id]!!)
                GeneratedArtworkPreparation(graph, owned, 20).prepare(ids)
            }
            withTimeout(5000) {
                while (ids.any { graph.extras.value[it]?.generatedArtwork == null }) delay(10)
            }
            assertEquals(
                graph.store.song(id)?.displayArtworkPath(),
                graph.store.song(ids[1])?.displayArtworkPath(),
            )
            val song = graph.store.song(id)!!
            assertNull(song.artworkPath)
            assertEquals(
                contentDigest(bytes),
                contentDigest(File(song.displayArtworkPath()!!).readBytes()),
            )
            assertEquals(before, graph.store.songs().map { it.id })
            assertEquals(1, calls.get())
            server.shutdown()
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                graph.online.value = OnlineSettings(endpoint, enabled = false)
                graph.extras.value = graph.extras.value - ids.toSet()
                GeneratedArtworkPreparation(graph, owned, 20).prepare(ids)
            }
            withTimeout(5000) {
                while (ids.any { graph.extras.value[it]?.generatedArtwork == null }) delay(10)
            }
            assertEquals(1, calls.get())
        } finally {
            owned.cancel()
            InstrumentationRegistry.getInstrumentation().runOnMainSync { graph.online.value = old }
            graph.store.removeSongs(ids)
            server.shutdown()
        }
    }
}
