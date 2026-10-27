package com.tonyredondo.sonora

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LyricsPreparationTest {
    private fun main(action: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(action)

    @Test
    fun fetchedLyricsArePersistedBeforeTheAlbumCorpusIsSubmitted() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val ids = List(2) { "lookup-qa-${UUID.randomUUID()}" }
        val songs = ids.mapIndexed { index, id ->
            Song(
                id,
                "content://lookup-qa/$id",
                "Song $index & verse",
                "Lookup QA",
                "Album ${ids.first()}",
                durationMs = 30000,
                trackNumber = index + 1,
                genre = "Rock",
                lyricsText = if (index == 0) "" else "[00:01]An existing phrase",
            )
        }
        val lookups = AtomicInteger()
        val albums = AtomicInteger()
        val server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val url = requireNotNull(request.requestUrl)
                    if (url.encodedPath == "/v1/lyrics") {
                        lookups.incrementAndGet()
                        check(url.queryParameter("title") == songs[0].title)
                        return MockResponse()
                            .setBody(
                                JSONObject()
                                    .put("provider", "lrclib")
                                    .put(
                                        "data",
                                        JSONObject()
                                            .put("id", 1)
                                            .put("trackName", songs[0].title)
                                            .put("artistName", songs[0].artist)
                                            .put("albumName", songs[0].album)
                                            .put("duration", 30)
                                            .put("instrumental", false)
                                            .put(
                                                "syncedLyrics",
                                                "[00:01]Fetched first phrase\n[00:20]Fetched final phrase",
                                            ),
                                    )
                                    .toString(),
                            )
                    }
                    val input = JSONObject(request.body.readUtf8())
                    val value =
                        if (url.encodedPath == "/v1/lyrics/translate")
                            JSONObject()
                                .put("model", "gpt-6.1-sol")
                                .put("effort", "medium")
                                .put(
                                    "lines",
                                    JSONArray(
                                        (0 until input.getJSONArray("lines").length()).map { index
                                            ->
                                            JSONObject()
                                                .put("id", index)
                                                .put("text", "Translated phrase $index")
                                        },
                                    ),
                                )
                        else {
                            if (url.encodedPath == "/v1/albums/interpret") {
                                val tracks = input.getJSONObject("album").getJSONArray("tracks")
                                check(tracks.length() == 2)
                                check(
                                    tracks
                                        .getJSONObject(0)
                                        .getString("lyrics")
                                        .contains("Fetched final phrase"),
                                )
                                check(
                                    tracks
                                        .getJSONObject(1)
                                        .getString("lyrics")
                                        .contains("existing phrase"),
                                )
                                albums.incrementAndGet()
                            }
                            JSONObject()
                                .put("model", "gpt-6-astra")
                                .put("effort", "medium")
                                .put("explanation", "Complete QA reading.")
                        }
                    return MockResponse().setBody(value.toString())
                }
            }
        server.start()
        try {
            graph.store.saveSongs(songs)
            graph.refresh()
            val settings = OnlineSettings(server.url("/").toString())
            main {
                graph.online.value = settings
                graph.setQueue(ids)
            }
            withTimeout(15000) {
                while (
                    ids.any { graph.extras.value[it]?.albumMeaning == null } ||
                        graph.extras.value[ids[0]]?.translation?.size != 2 ||
                        graph.extras.value[ids[1]]?.translation?.size != 1
                ) delay(20)
            }
            assertEquals(1, lookups.get())
            assertEquals(1, albums.get())
            assertTrue(
                requireNotNull(graph.store.song(ids[0]))
                    .lyricsText
                    .contains("Fetched final phrase"),
            )
            assertEquals("Translated phrase 1", graph.extras.value[ids[0]]?.translation?.get(1))
        } finally {
            main {
                graph.setQueue(emptyList())
                graph.online.value = previous
            }
            graph.store.removeSongs(ids)
            graph.refresh()
            server.shutdown()
        }
    }

    @Test
    fun aLookupNeverOverwritesLyricsEditedWhileTheHttpRequestIsRunning() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val id = "edited-lyrics-${UUID.randomUUID()}"
        val song =
            Song(
                id,
                "content://edited-lyrics/$id",
                "Original title $id",
                "QA artist",
                "QA album",
                durationMs = 30000,
            )
        val arrived = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.requestUrl?.encodedPath != "/v1/lyrics")
                        return MockResponse()
                            .setResponseCode(503)
                            .setBody("{\"error\":\"codex_disabled\"}")
                    arrived.countDown()
                    check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                    return MockResponse()
                        .setBody(
                            JSONObject()
                                .put(
                                    "data",
                                    JSONObject()
                                        .put("trackName", song.title)
                                        .put("artistName", song.artist)
                                        .put("albumName", song.album)
                                        .put("duration", 30)
                                        .put("instrumental", false)
                                        .put("syncedLyrics", "[00:01]Fetched text"),
                                )
                                .toString(),
                        )
                }
            }
        server.start()
        try {
            graph.store.saveSongs(listOf(song))
            graph.refresh()
            val settings = OnlineSettings(server.url("/").toString())
            main {
                graph.online.value = settings
                graph.lyrics.prepare(listOf(id))
            }
            assertTrue(arrived.await(5, java.util.concurrent.TimeUnit.SECONDS))
            graph.store.saveSongs(
                listOf(song.copy(lyricsText = "[00:02]My complete edited phrase")),
            )
            release.countDown()
            withTimeout(5000) { while (graph.lyrics.pending(id)) delay(10) }
            assertEquals("[00:02]My complete edited phrase", graph.store.song(id)?.lyricsText)
        } finally {
            release.countDown()
            main { graph.online.value = previous }
            graph.store.removeSongs(listOf(id))
            graph.refresh()
            server.shutdown()
        }
    }

    @Test
    fun aMissingLyricIsCachedWithoutRepeatedProviderRequests() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val id = "missing-lyrics-${UUID.randomUUID()}"
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(404).setBody("{\"error\":\"not_found\"}"))
        server.start()
        try {
            graph.store.saveSongs(
                listOf(
                    Song(
                        id,
                        "content://missing-lyrics/$id",
                        "Missing title $id",
                        "QA artist",
                        "QA album $id",
                        durationMs = 30000,
                    ),
                ),
            )
            graph.refresh()
            val settings = OnlineSettings(server.url("/").toString())
            main {
                graph.online.value = settings
                graph.lyrics.prepare(listOf(id))
            }
            withTimeout(5000) { while (graph.lyrics.pending(id)) delay(10) }
            assertEquals(1, server.requestCount)
            main { graph.lyrics.prepare(listOf(id)) }
            withTimeout(5000) { while (graph.lyrics.pending(id)) delay(10) }
            assertEquals(1, server.requestCount)
            assertEquals(
                PreparationState.UNAVAILABLE,
                graph.extras.value[id]?.progress?.get(PreparationStage.LYRICS)?.state,
            )
        } finally {
            main { graph.online.value = previous }
            graph.store.removeSongs(listOf(id))
            graph.refresh()
            server.shutdown()
        }
    }
}
