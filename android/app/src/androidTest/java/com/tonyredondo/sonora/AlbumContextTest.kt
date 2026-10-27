package com.tonyredondo.sonora

import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AlbumContextTest {
    @Test
    fun albumIncludesTagsAndLyricsOfKnownTracksOutsideQueueWithoutInterpretingThoseSongs() =
        runBlocking {
            val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
            withTimeout(5000) { while (!graph.ready.value) delay(10) }
            val previous = graph.online.value
            val ids = List(2) { "album-context-${UUID.randomUUID()}" }
            val files = ids.map { File(graph.application.cacheDir, "$it.wav") }
            files.forEach { file ->
                InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("fixture.wav")
                    .use { input -> file.outputStream().use(input::copyTo) }
            }
            // Give this fixture distinct audio so other retained queue jobs cannot be counted as
            // one of this album's tag requests. The real decoder/sample upload path is unchanged.
            files.forEachIndexed { index, file ->
                val bytes = file.readBytes()
                val salt =
                    java.security.MessageDigest.getInstance("SHA-256")
                        .digest(ids[index].toByteArray())
                var chunk = 12
                var dataOffset: Int? = null
                while (chunk + 8 <= bytes.size) {
                    val length =
                        java.nio.ByteBuffer.wrap(bytes, chunk + 4, 4)
                            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                            .int
                    require(length >= 0 && chunk.toLong() + 8 + length <= bytes.size)
                    if (String(bytes, chunk, 4, Charsets.US_ASCII) == "data") {
                        dataOffset = chunk + 8
                        break
                    }
                    chunk += 8 + length + (length and 1)
                }
                val start = requireNotNull(dataOffset)
                repeat(256) { bytes[start + it] = salt[it % salt.size] }
                file.writeBytes(bytes)
            }
            val album = "Context QA ${ids.first()}"
            val characterCalls = AtomicInteger()
            val unrelatedCalls = AtomicInteger()
            val uploads = java.util.concurrent.ConcurrentHashMap<String, AtomicInteger>()
            val observed = java.util.concurrent.ConcurrentLinkedQueue<String>()
            val meanings = AtomicInteger()
            val albums = AtomicInteger()
            val server = MockWebServer()
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse {
                        val path = request.path?.substringBefore('?')
                        if (
                            path !in
                                listOf(
                                    "/v1/audio/character",
                                    "/v1/lyrics/translate",
                                    "/v1/lyrics/interpret",
                                    "/v1/albums/interpret",
                                )
                        )
                            return MockResponse()
                                .setResponseCode(503)
                                .setBody("{\"error\":\"codex_disabled\"}")
                        if (path == "/v1/audio/character") {
                            val received = request.body.readByteArray()
                            val digest = contentDigest(received)
                            observed.add(
                                "received:${received.size}:$digest; expected:" +
                                    ids.joinToString { id ->
                                        graph.store.song(id)?.let { song ->
                                            AudioPreviewStore(graph.application).read(song)?.let {
                                                bytes ->
                                                "$id:${bytes.size}:${contentDigest(bytes)}"
                                            }
                                        } ?: "$id:missing"
                                    },
                            )
                            val target = ids.firstOrNull { id ->
                                graph.store.song(id)?.let { song ->
                                    AudioPreviewStore(graph.application).read(song)?.let {
                                        contentDigest(it) == digest
                                    }
                                } == true
                            }
                            if (target == null) {
                                unrelatedCalls.incrementAndGet()
                                return MockResponse()
                                    .setResponseCode(503)
                                    .setBody("{\"error\":\"disabled\"}")
                            }
                            uploads.computeIfAbsent(target) { AtomicInteger() }.incrementAndGet()
                            characterCalls.incrementAndGet()
                            return MockResponse()
                                .setBody(
                                    """{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Indie Rock","score":0.7}],"moods":{"happy":0.1,"sad":0.8,"relaxed":0.7,"aggressive":0.1}}""",
                                )
                        }
                        val input = JSONObject(request.body.readUtf8())
                        val contextAlbum =
                            if (path == "/v1/albums/interpret")
                                input.optJSONObject("album")?.optString("title")
                            else input.optJSONObject("context")?.optString("album")
                        if (
                            path in listOf("/v1/albums/interpret", "/v1/lyrics/interpret") &&
                                contextAlbum != album
                        )
                            return MockResponse()
                                .setResponseCode(503)
                                .setBody("{\"error\":\"disabled\"}")
                        if (path == "/v1/lyrics/translate")
                            return MockResponse()
                                .setBody(
                                    """{"model":"gpt-6.1-sol","effort":"medium","lines":[{"id":0,"text":"La primera frase."}]}""",
                                )
                        if (path == "/v1/albums/interpret") {
                            val tracks = input.getJSONObject("album").getJSONArray("tracks")
                            assertEquals(2, tracks.length())
                            assertEquals(observed.joinToString(" | "), 2, characterCalls.get())
                            (0..1).forEach { index ->
                                val track = tracks.getJSONObject(index)
                                assertEquals(
                                    "Track ${index+1}",
                                    track.getJSONObject("context").getString("title"),
                                )
                                assertEquals(
                                    "Rock---Indie Rock",
                                    track
                                        .getJSONObject("context")
                                        .getJSONArray("styles")
                                        .getString(0),
                                )
                                assertEquals(
                                    "Complete phrase ${index+1}",
                                    track.getString("lyrics"),
                                )
                            }
                            albums.incrementAndGet()
                        } else {
                            meanings.incrementAndGet()
                            assertEquals(
                                "Track 1",
                                input.getJSONObject("context").getString("title"),
                            )
                        }
                        return MockResponse()
                            .setBody(
                                """{"model":"gpt-6-astra","effort":"medium","explanation":"La lectura con todas las canciones del álbum."}""",
                            )
                    }
                }
            server.start()
            val endpoint = server.url("/").toString()
            fun main(action: () -> Unit) =
                InstrumentationRegistry.getInstrumentation().runOnMainSync(action)
            try {
                graph.store.saveSongs(
                    ids.mapIndexed { i, id ->
                        Song(
                            id,
                            android.net.Uri.fromFile(files[i]).toString(),
                            "Track ${i+1}",
                            "QA Artist",
                            album,
                            durationMs = 30000,
                            trackNumber = i + 1,
                            lyricsText = "[00:01]Complete phrase ${i+1}",
                            size = files[i].length(),
                            modified = files[i].lastModified(),
                        )
                    },
                )
                main {
                    graph.online.value = OnlineSettings(endpoint)
                    graph.setQueue(listOf(ids.first()))
                }
                withTimeout(15000) {
                    while (graph.extras.value[ids.first()]?.albumMeaning == null) delay(10)
                }
                assertEquals(2, characterCalls.get())
                ids.forEach { assertEquals(1, uploads[it]?.get()) }
                println("Album QA unrelated background uploads: ${unrelatedCalls.get()}")
                assertEquals(1, albums.get())
                assertEquals(1, meanings.get())
                assertNull(graph.extras.value[ids[1]]?.meaning)
            } finally {
                main {
                    graph.online.value = previous
                    graph.setQueue(emptyList())
                }
                graph.store.removeSongs(ids)
                files.forEach { it.delete() }
                server.shutdown()
            }
        }
}
