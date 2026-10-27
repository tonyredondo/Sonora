package com.tonyredondo.sonora

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemotePreparationTest {
    private fun main(action: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(action)

    @Test
    fun changingServerReleasesAllFourTextWorkersWithoutWaitingForOldResponses() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val oldId = "old-server-${UUID.randomUUID()}"
        val ids = List(4) { "new-server-${UUID.randomUUID()}" }
        val oldArrived = CountDownLatch(2)
        val releaseOld = CountDownLatch(1)
        val newArrived = CountDownLatch(4)
        val calls = AtomicInteger()
        val active = AtomicInteger()
        val peak = AtomicInteger()
        val first = MockWebServer()
        val second = MockWebServer()
        first.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    oldArrived.countDown()
                    releaseOld.await(8, TimeUnit.SECONDS)
                    return MockResponse()
                        .setResponseCode(503)
                        .setBody("{\"error\":\"codex_unavailable\"}")
                }
            }
        second.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val count = active.incrementAndGet()
                    peak.updateAndGet { maxOf(it, count) }
                    calls.incrementAndGet()
                    try {
                        newArrived.countDown()
                        check(newArrived.await(4, TimeUnit.SECONDS))
                        val input = JSONObject(request.body.readUtf8())
                        return if (request.path == "/v1/lyrics/translate")
                            MockResponse()
                                .setBody(
                                    JSONObject()
                                        .put("model", "gpt-6.1-sol")
                                        .put("effort", "medium")
                                        .put(
                                            "lines",
                                            JSONArray()
                                                .put(
                                                    JSONObject()
                                                        .put("id", 0)
                                                        .put("text", "La frase traducida."),
                                                ),
                                        )
                                        .toString(),
                                )
                        else
                            MockResponse()
                                .setBody(
                                    """{"model":"gpt-6-astra","effort":"medium","explanation":"La explicación del servidor nuevo."}""",
                                )
                    } finally {
                        active.decrementAndGet()
                    }
                }
            }
        first.start()
        second.start()
        val firstSettings = OnlineSettings(first.url("/").toString())
        val nextSettings = OnlineSettings(second.url("/").toString())
        try {
            graph.store.saveSongs(
                (listOf(oldId) + ids).map {
                    Song(
                        it,
                        "content://server-switch/$it",
                        it,
                        lyricsText = "[00:01]A complete shared phrase ${ids.first()}",
                    )
                },
            )
            main {
                graph.setQueue(emptyList())
                graph.online.value = firstSettings
                graph.remote.prepare(listOf(oldId))
            }
            assertTrue(oldArrived.await(3, TimeUnit.SECONDS))
            main {
                graph.online.value = nextSettings
                graph.remote.prepare(ids)
            }
            withTimeout(3500) {
                while (
                    ids.any {
                        graph.extras.value[it]?.meaning == null ||
                            graph.extras.value[it]?.translation?.size != 1
                    }
                ) delay(10)
            }
            assertEquals(1L, releaseOld.count)
            assertEquals(4, peak.get())
            assertEquals(5, calls.get())
        } finally {
            releaseOld.countDown()
            main { graph.online.value = previous }
            graph.store.removeSongs(listOf(oldId) + ids)
            first.shutdown()
            second.shutdown()
        }
    }

    @Test
    fun fourActualHttpCallsRunTogetherAndResultsRestoreOfflineForEveryAlbumTrack() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.online.value
        val token = "synthetic-native-contract-token"
        val ids = List(4) { "remote-qa-${UUID.randomUUID()}" }
        val active = AtomicInteger()
        val peak = AtomicInteger()
        val requests = AtomicInteger()
        val arrivals = CountDownLatch(4)
        val server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val count = active.incrementAndGet()
                    peak.updateAndGet { maxOf(it, count) }
                    requests.incrementAndGet()
                    try {
                        if (request.getHeader("Authorization") != "Bearer $token")
                            return MockResponse().setResponseCode(401).setBody("{}")
                        arrivals.countDown()
                        if (!arrivals.await(5, TimeUnit.SECONDS))
                            return MockResponse()
                                .setResponseCode(504)
                                .setBody("{\"error\":\"codex_timeout\"}")
                        val input = JSONObject(request.body.readUtf8())
                        val value =
                            if (request.path == "/v1/lyrics/translate") {
                                JSONObject()
                                    .put("model", "gpt-6.1-sol")
                                    .put("effort", "medium")
                                    .put(
                                        "lines",
                                        JSONArray(
                                            (0 until input.getJSONArray("lines").length()).map {
                                                index ->
                                                val line =
                                                    input.getJSONArray("lines").getJSONObject(index)
                                                JSONObject()
                                                    .put("id", line.getInt("id"))
                                                    .put("text", "Traducción ${line.getInt("id")}")
                                            },
                                        ),
                                    )
                            } else {
                                if (request.path == "/v1/albums/interpret")
                                    check(
                                        input
                                            .getJSONObject("album")
                                            .getJSONArray("tracks")
                                            .length() == 2,
                                    )
                                JSONObject()
                                    .put("model", "gpt-6-astra")
                                    .put("effort", "medium")
                                    .put("explanation", "Una lectura del texto de prueba.")
                            }
                        return MockResponse()
                            .setHeader("Content-Type", "application/json")
                            .setBody(value.toString())
                    } finally {
                        active.decrementAndGet()
                    }
                }
            }
        server.start()
        try {
            graph.store.saveSongs(
                ids.mapIndexed { index, id ->
                    Song(
                        id,
                        "content://remote-qa/$id",
                        "Song $index",
                        "QA artist",
                        "QA album ${index/2}",
                        trackNumber = index + 1,
                        lyricsText =
                            "[00:01]First complete phrase ${ids.first()}\n[00:10]Second complete phrase",
                    )
                },
            )
            val online = OnlineSettings(server.url("/").toString(), token)
            main {
                graph.online.value = online
                graph.remote.prepare(ids)
            }
            suspend fun ready() =
                withTimeout(15000) {
                    while (
                        ids.any { id ->
                            val extra = graph.extras.value[id]
                            extra?.translation?.size != 2 ||
                                extra.meaning == null ||
                                extra.albumMeaning == null
                        }
                    ) delay(20)
                }
            // Four identical lyric documents share one translation:1 translation+4 song readings+2
            // album readings.
            ready()
            assertEquals(4, peak.get())
            assertEquals(7, requests.get())
            server.shutdown()
            main {
                graph.extras.value = graph.extras.value - ids.toSet()
                graph.online.value = OnlineSettings(online.endpoint, token, enabled = false)
                graph.remote.prepare(ids)
            }
            ready()
            assertEquals(7, requests.get())
            ids.forEach {
                assertEquals("Traducción 1", graph.extras.value[it]?.translation?.get(1))
            }
        } finally {
            main { graph.online.value = previous }
            graph.store.removeSongs(ids)
            server.shutdown()
        }
    }

    @Test
    fun lateResponsesStayWithTheirLanguageAndDoNotOverwriteTheCurrentPage() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val oldSettings = graph.online.value
        val id = "language-qa-${UUID.randomUUID()}"
        val arrivals = CountDownLatch(2)
        val release = CountDownLatch(1)
        val requests = AtomicInteger()
        val finished = AtomicInteger()
        val server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests.incrementAndGet()
                    val input = JSONObject(request.body.readUtf8())
                    val language = input.optString("target_language", input.optString("language"))
                    if (language == "es") {
                        arrivals.countDown()
                        check(release.await(10, TimeUnit.SECONDS))
                    }
                    val value =
                        if (request.path == "/v1/lyrics/translate")
                            JSONObject()
                                .put("model", "gpt-6.1-sol")
                                .put("effort", "medium")
                                .put(
                                    "lines",
                                    JSONArray()
                                        .put(
                                            JSONObject()
                                                .put("id", 0)
                                                .put("text", "$language phrase"),
                                        ),
                                )
                        else
                            JSONObject()
                                .put("model", "gpt-6-astra")
                                .put("effort", "medium")
                                .put("explanation", "$language about")
                    if (language == "es") finished.incrementAndGet()
                    return MockResponse().setBody(value.toString())
                }
            }
        server.start()
        try {
            val song =
                Song(
                    id,
                    "content://language-qa/$id",
                    "Language QA",
                    lyricsText = "[00:01]A complete phrase $id",
                )
            graph.store.saveSongs(listOf(song))
            val endpoint = server.url("/").toString()
            main {
                graph.online.value = OnlineSettings(endpoint, language = "es")
                graph.remote.prepare(listOf(id))
            }
            assertTrue(arrivals.await(5, TimeUnit.SECONDS))
            main {
                graph.online.value = OnlineSettings(endpoint, language = "en")
                graph.remote.prepare(listOf(id))
            }
            suspend fun ready(language: String) =
                withTimeout(10000) {
                    while (
                        graph.extras.value[id]?.meaning != "$language about" ||
                            graph.extras.value[id]?.translation?.get(0) != "$language phrase"
                    ) delay(20)
                }
            ready("en")
            release.countDown()
            withTimeout(5000) { while (finished.get() != 2) delay(20) }
            val esSettings = OnlineSettings(endpoint, language = "es")
            val esKeys =
                listOf(
                    remoteCacheKey(
                        esSettings,
                        "v1/lyrics/translate",
                        ProxyContent.translationInput(LyricsDocument.parse(song.lyricsText), "es"),
                    ),
                    remoteCacheKey(
                        esSettings,
                        "v1/lyrics/interpret",
                        ProxyContent.meaningInput(song, SongExtras(), "es"),
                    ),
                )
            withTimeout(5000) { while (esKeys.any { graph.store.state(it) == null }) delay(20) }
            assertEquals("en about", graph.extras.value[id]?.meaning)
            main {
                graph.extras.value = graph.extras.value - id
                graph.online.value = OnlineSettings(endpoint, language = "es", enabled = false)
                graph.remote.prepare(listOf(id))
            }
            ready("es")
            assertEquals(4, requests.get())
        } finally {
            release.countDown()
            main { graph.online.value = oldSettings }
            graph.store.removeSongs(listOf(id))
            server.shutdown()
        }
    }

    @Test
    fun keystoreRoundTripKeepsTheTokenOutOfPlainPreferences() {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val store = OnlineSettingsStore(app)
        runBlocking { withTimeout(5000) { while (!app.graph.ready.value) delay(10) } }
        val previous = store.read()
        val secret = "synthetic-keystore-${UUID.randomUUID()}"
        try {
            store.write(OnlineSettings("https://example.invalid/sonora/", secret, "en", false))
            assertEquals(secret, store.read().token)
            assertFalse(
                app.getSharedPreferences("sonora_online", 0)
                    .getString("token", "")
                    .orEmpty()
                    .contains(secret),
            )
        } finally {
            store.write(previous)
        }
    }
}
