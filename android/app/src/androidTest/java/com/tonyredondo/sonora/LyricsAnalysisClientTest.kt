package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LyricsAnalysisClientTest {
    @Test
    fun changingTheConnectionCancelsTheUploadWithoutRetryingOrCachingAnUnknownResult() =
        runBlocking {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val id = UUID.randomUUID().toString()
            val store = LibraryStore(context, "lyrics-cancel-$id.sqlite")
            val source = File(context.cacheDir, "lyrics-cancel-$id.wav")
            val server = MockWebServer()
            val release = java.util.concurrent.CountDownLatch(1)
            try {
                InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("fixture.wav")
                    .use { input -> source.outputStream().use(input::copyTo) }
                val song = LocalAudio(context).read(Uri.fromFile(source))
                val original = contentDigest(source.readBytes())
                server.dispatcher =
                    object : Dispatcher() {
                        override fun dispatch(request: RecordedRequest): MockResponse {
                            check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                            return MockResponse().setBody("{}")
                        }
                    }
                server.start()
                val settings =
                    MutableStateFlow(OnlineSettings(server.url("/").toString(), "synthetic-cancel"))
                val task =
                    async(Dispatchers.Default) {
                        runCatching {
                            LyricsAnalysisClient(context, store, settings).transcribe(song)
                        }
                    }
                assertNotNull(
                    withContext(Dispatchers.IO) {
                        server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)
                    },
                )
                settings.value =
                    OnlineSettings(server.url("/").toString(), "synthetic-cancel", enabled = false)
                val result = withTimeout(2000) { task.await() }
                assertEquals("connection_changed", (result.exceptionOrNull() as ProxyFailure).code)
                assertEquals(1, server.requestCount)
                assertEquals(original, contentDigest(source.readBytes()))
            } finally {
                release.countDown()
                server.shutdown()
                store.close()
                context.deleteDatabase("lyrics-cancel-$id.sqlite")
                source.delete()
            }
        }

    @Test
    fun aCacheWriteFailureReturnsTheAnalysisWithAnExplicitWarning() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val id = UUID.randomUUID().toString()
        val name = "lyrics-cache-failure-$id.sqlite"
        val store = LibraryStore(context, name)
        val source = File(context.cacheDir, "lyrics-cache-failure-$id.wav")
        val server = MockWebServer()
        var database: android.database.sqlite.SQLiteDatabase? = null
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use {
                input ->
                source.outputStream().use(input::copyTo)
            }
            val song = LocalAudio(context).read(Uri.fromFile(source))
            val body =
                LyricsAudioPreparation(context).prepare(song).use { audio ->
                    JSONObject()
                        .put(
                            "data",
                            JSONObject()
                                .put("audio_sha256", audio.sha256)
                                .put("duration", audio.duration)
                                .put("model_id", "scribe_v2")
                                .put("plain_lyrics", "")
                                .put("synced_lyrics", ""),
                        )
                }
            store.putState("qa-owned", "ready")
            database =
                android.database.sqlite.SQLiteDatabase.openDatabase(
                    context.getDatabasePath(name).path,
                    null,
                    android.database.sqlite.SQLiteDatabase.OPEN_READWRITE,
                )
            database.execSQL(
                "CREATE TRIGGER qa_cache_failure BEFORE INSERT ON state WHEN NEW.key LIKE 'lyrics-analysis-v1:%' BEGIN SELECT RAISE(ABORT,'QA full cache'); END",
            )
            server.enqueue(MockResponse().setBody(body.toString()))
            server.start()
            val result =
                LyricsAnalysisClient(
                        context,
                        store,
                        MutableStateFlow(
                            OnlineSettings(server.url("/").toString(), "synthetic-cache"),
                        ),
                    )
                    .transcribe(song)
            assertNull(result.transcript)
            assertFalse(result.cached)
            assertTrue(result.warning!!.contains("No se pudo guardar"))
            assertEquals(1, server.requestCount)
        } finally {
            database?.execSQL("DROP TRIGGER IF EXISTS qa_cache_failure")
            database?.close()
            server.shutdown()
            store.close()
            context.deleteDatabase(name)
            source.delete()
        }
    }

    @Test
    fun multipartAnalysisIsBoundToItsAudioAndTextAndRestoresCachedAndSilentResultsOffline() =
        runBlocking {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val id = UUID.randomUUID().toString()
            val database = "lyrics-analysis-$id.sqlite"
            val store = LibraryStore(context, database)
            val source = File(context.cacheDir, "lyrics-client-$id.wav")
            val server = MockWebServer()
            val transcriptions = AtomicInteger()
            val alignments = AtomicInteger()
            val silent = java.util.concurrent.atomic.AtomicBoolean(false)
            val serverFailure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse =
                        try {
                            respond(request)
                        } catch (error: Throwable) {
                            serverFailure.set(error)
                            MockResponse()
                                .setResponseCode(500)
                                .setBody("{\"error\":\"fixture_failed\"}")
                        }

                    private fun respond(request: RecordedRequest): MockResponse {
                        assertEquals(
                            "Bearer synthetic-lyrics-token",
                            request.getHeader("Authorization"),
                        )
                        val boundary =
                            request.getHeader("Content-Type")!!.substringAfter("boundary=")
                        val body = request.body.readByteArray()
                        val text = String(body, Charsets.ISO_8859_1)
                        val fileHeader = text.indexOf("filename=\"audio.wav\"")
                        assertTrue(fileHeader >= 0)
                        val begin = text.indexOf("\r\n\r\n", fileHeader) + 4
                        val end = text.lastIndexOf("\r\n--$boundary")
                        val pcm = body.copyOfRange(begin, end)
                        assertEquals("RIFF", String(pcm, 0, 4))
                        val duration = (pcm.size - 44) / 32000.0
                        val value =
                            JSONObject()
                                .put("audio_sha256", contentDigest(pcm))
                                .put("duration", duration)
                        when (request.path) {
                            "/v1/lyrics/transcribe" -> {
                                transcriptions.incrementAndGet()
                                value
                                    .put("model_id", "scribe_v2")
                                    .put(
                                        "plain_lyrics",
                                        if (silent.get()) "" else "Bright road\nWe return",
                                    )
                                    .put(
                                        "synced_lyrics",
                                        if (silent.get()) ""
                                        else "[00:00.20]Bright road\n[00:01.40]We return",
                                    )
                            }
                            "/v1/lyrics/align" -> {
                                alignments.incrementAndGet()
                                val header = text.indexOf("name=\"text\"")
                                val content = text.indexOf("\r\n\r\n", header) + 4
                                val stop = text.indexOf("\r\n--$boundary", content)
                                assertEquals(
                                    "Bright road\nWe return",
                                    text.substring(content, stop),
                                )
                                value
                                    .put("text_sha256", contentDigest("Bright road\nWe return"))
                                    .put("plain_lyrics", "Bright road\nWe return")
                                    .put(
                                        "synced_lyrics",
                                        "[00:00.30]Bright road\n[00:02.00]We return",
                                    )
                            }
                            else -> return MockResponse().setResponseCode(404)
                        }
                        return MockResponse().setBody(JSONObject().put("data", value).toString())
                    }
                }
            try {
                InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("fixture.wav")
                    .use { input -> source.outputStream().use(input::copyTo) }
                val original = contentDigest(source.readBytes())
                val song = LocalAudio(context).read(Uri.fromFile(source))
                server.start()
                val settings =
                    MutableStateFlow(
                        OnlineSettings(server.url("/").toString(), "synthetic-lyrics-token"),
                    )
                val client = LyricsAnalysisClient(context, store, settings)
                val transcript = client.transcribe(song)
                assertFalse(transcript.cached)
                assertEquals("Bright road\nWe return", transcript.transcript!!.plainText)
                val alignment = client.align(song, "[00:01]Bright road\n[00:03]We return")
                assertFalse(alignment.cached)
                assertEquals(
                    listOf(300L, 2000L),
                    LyricsDocument.parse(alignment.text).lines.map { it.timeMs },
                )
                assertEquals(original, contentDigest(source.readBytes()))
                // An independent CUE interval has different PCM and therefore a distinct negative
                // cache.
                val cue = CueSegment("file:///silent.cue", 1, 75, 225).applyTo(song)
                silent.set(true)
                assertNull(client.transcribe(cue).transcript)
                source.delete()
                settings.value =
                    OnlineSettings(
                        server.url("/").toString(),
                        "synthetic-lyrics-token",
                        enabled = false,
                    )
                assertTrue(LyricsAnalysisClient(context, store, settings).transcribe(song).cached)
                assertTrue(client.align(song, "Bright road\nWe return").cached)
                assertTrue(client.transcribe(cue).cached)
                assertNull(client.transcribe(cue).transcript)
                assertEquals(2, transcriptions.get())
                assertEquals(1, alignments.get())
            } catch (error: Throwable) {
                throw serverFailure.get() ?: error
            } finally {
                server.shutdown()
                store.close()
                context.deleteDatabase(database)
                source.delete()
            }
        }
}
