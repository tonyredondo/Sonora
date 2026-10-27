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

class AudioCharacterPreparationTest {
    private fun main(action: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(action)

    @Test
    fun sampledAudioIsUploadedAndContextWaitsForTagsThenRestoresOffline() = runBlocking {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val old = graph.online.value
        val id = "character-qa-${UUID.randomUUID()}"
        val source = File(graph.application.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            source.outputStream().use(input::copyTo)
        }
        val original = contentDigest(source.readBytes())
        val characterCalls = AtomicInteger()
        val meaningCalls = AtomicInteger()
        val server = MockWebServer()
        val character =
            """{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Alternative Rock","score":0.85}],"moods":{"happy":0.1,"sad":0.8,"relaxed":0.7,"aggressive":0.1}}"""
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    check(request.getHeader("Authorization") == "Bearer synthetic-character-token")
                    if (request.path == "/v1/artwork/jobs")
                        return MockResponse()
                            .setResponseCode(503)
                            .setBody("{\"error\":\"codex_disabled\"}")
                    return if (request.path == "/v1/audio/character") {
                        assertEquals("audio/wav", request.getHeader("Content-Type"))
                        val audio = request.body.readByteArray()
                        assertTrue(audio.size in 32044..2_880_044)
                        assertEquals("RIFF", String(audio.copyOfRange(0, 4)))
                        characterCalls.incrementAndGet()
                        MockResponse().setBody(character)
                    } else {
                        val input = JSONObject(request.body.readUtf8())
                        if (request.path == "/v1/lyrics/translate")
                            MockResponse()
                                .setBody(
                                    """{"model":"gpt-6.1-sol","effort":"medium","lines":[{"id":0,"text":"Una frase entera"}]}""",
                                )
                        else {
                            meaningCalls.incrementAndGet()
                            assertEquals(1, characterCalls.get())
                            assertEquals(
                                "Rock---Alternative Rock",
                                input.getJSONObject("context").getJSONArray("styles").getString(0),
                            )
                            MockResponse()
                                .setBody(
                                    """{"model":"gpt-6-astra","effort":"medium","explanation":"Una lectura con el contexto musical."}""",
                                )
                        }
                    }
                }
            }
        server.start()
        try {
            val song =
                Song(
                    id,
                    android.net.Uri.fromFile(source).toString(),
                    "Character QA",
                    lyricsText = "[00:01]One complete phrase $id",
                    durationMs = 30000,
                    size = source.length(),
                    modified = source.lastModified(),
                )
            graph.store.saveSongs(listOf(song))
            val settings = OnlineSettings(server.url("/").toString(), "synthetic-character-token")
            main {
                graph.online.value = settings
                graph.setQueue(listOf(id))
            }
            withTimeout(15000) { while (graph.extras.value[id]?.meaning == null) delay(10) }
            assertEquals(listOf("sad", "relaxed"), graph.extras.value[id]?.moods)
            assertEquals(1, meaningCalls.get())
            assertEquals(1, characterCalls.get())
            server.shutdown()
            main {
                graph.extras.value = graph.extras.value - id
                graph.online.value =
                    OnlineSettings(settings.endpoint, settings.token, enabled = false)
                graph.character.prepare(listOf(id))
            }
            withTimeout(5000) { while (graph.extras.value[id]?.character == null) delay(10) }
            assertEquals(1, characterCalls.get())
            assertEquals(original, contentDigest(source.readBytes()))
        } finally {
            main {
                graph.online.value = old
                graph.setQueue(emptyList())
            }
            graph.store.removeSongs(listOf(id))
            source.delete()
            server.shutdown()
        }
    }
}
