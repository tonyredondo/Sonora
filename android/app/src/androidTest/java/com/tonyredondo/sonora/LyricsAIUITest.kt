package com.tonyredondo.sonora

import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LyricsAIUITest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun alignmentAndRepairRequireReviewPreserveDraftAcrossRotationAndOnlySaveExplicitly() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val prior = graph.online.value
        val id = "lyrics-ai-ui-${UUID.randomUUID()}"
        val file = File(rule.activity.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val bytes = file.readBytes()
        val view = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        while (String(bytes, offset, 4) != "data") {
            val size = view.getInt(offset + 4)
            offset += 8 + size + (size % 2)
        }
        // A new PCM fingerprint avoids reusing a prior UI run's valid immutable analysis.
        val salt = java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray())
        for (index in salt.indices) bytes[offset + 8 + index] = salt[index]
        file.writeBytes(bytes)
        val original = contentDigest(file.readBytes())
        val song =
            LocalAudio(rule.activity)
                .read(Uri.fromFile(file))
                .copy(
                    id = id,
                    title = "Revisión de letras QA",
                    lyricsText = "Bright roan\nWe return",
                )
        val released = CountDownLatch(1)
        val arrived = CountDownLatch(1)
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse =
                    try {
                        respond(request)
                    } catch (error: Throwable) {
                        failure.set(error)
                        MockResponse()
                            .setResponseCode(500)
                            .setBody("{\"error\":\"fixture_failed\"}")
                    }

                private fun respond(request: RecordedRequest): MockResponse {
                    if (request.path !in listOf("/v1/lyrics/align", "/v1/lyrics/transcribe"))
                        return MockResponse()
                            .setResponseCode(404)
                            .setBody("{\"error\":\"not_found\"}")
                    requests.incrementAndGet()
                    val body = request.body.readByteArray()
                    val latin = String(body, Charsets.ISO_8859_1)
                    val boundary = request.getHeader("Content-Type")!!.substringAfter("boundary=")
                    val start =
                        latin.indexOf("\r\n\r\n", latin.indexOf("filename=\"audio.wav\"")) + 4
                    val end = latin.lastIndexOf("\r\n--$boundary")
                    val pcm = body.copyOfRange(start, end)
                    val value =
                        JSONObject()
                            .put("audio_sha256", contentDigest(pcm))
                            .put("duration", (pcm.size - 44) / 32000.0)
                    if (request.path == "/v1/lyrics/align") {
                        arrived.countDown()
                        check(released.await(15, TimeUnit.SECONDS))
                        value
                            .put("plain_lyrics", "Bright roan\nWe return")
                            .put("text_sha256", contentDigest("Bright roan\nWe return"))
                            .put("synced_lyrics", "[00:00.50]Bright roan\n[00:02.00]We return")
                    } else
                        value
                            .put("model_id", "scribe_v2")
                            .put("plain_lyrics", "Bright road\nWe return")
                            .put("synced_lyrics", "[00:00.50]Bright road\n[00:02.00]We return")
                    return MockResponse().setBody(JSONObject().put("data", value).toString())
                }
            }
        server.start()
        val connection = OnlineSettings(server.url("/").toString(), "synthetic-lyrics-ui")
        var model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
        try {
            graph.store.saveSongs(listOf(song))
            runBlocking { graph.refresh() }
            rule.runOnUiThread {
                graph.online.value = connection
                model.editLyrics(song)
            }
            rule.onNodeWithContentDescription("Herramientas de letras con IA").performClick()
            rule.onNodeWithText("Sincronizar con IA").performClick()
            rule.onNodeWithText("Analizar").performClick()
            rule.waitUntil(10000) { arrived.count == 0L }
            rule.onNodeWithTag("lyricsAIPhase").assertIsDisplayed()
            rule.activityRule.scenario.recreate()
            model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
            rule.onNodeWithTag("lyricsAIPhase").assertIsDisplayed()
            released.countDown()
            rule.waitUntil(10000) { model.lyricsAI.state.value?.candidate != null }
            rule.runOnIdle {
                assertEquals(song.lyricsText, model.lyricsEditorText.value)
                assertEquals(song.lyricsText, graph.store.song(id)!!.lyricsText)
            }
            rule.onNodeWithText("Usar en el editor").performClick()
            rule
                .onNodeWithTag("lyricsTextInput")
                .assertTextEquals("[00:00.50]Bright roan\n[00:02.00]We return")
            rule.onNodeWithContentDescription("Herramientas de letras con IA").performClick()
            rule.onNodeWithText("Reparar con IA").performClick()
            rule.onNodeWithText("Analizar").performClick()
            rule.waitUntil(10000) { model.lyricsAI.state.value?.review != null }
            rule.onNodeWithText("Seleccionar sugerencias").performClick()
            rule.onNodeWithText("Vista previa").performClick()
            rule.onNodeWithText("Bright road", useUnmergedTree = true).assertIsDisplayed()
            screenshot("lyrics-ai-review")
            rule
                .onNode(hasText("Cancelar") and hasAnySibling(hasText("Reparar letra")))
                .performClick()
            rule
                .onNodeWithTag("lyricsTextInput")
                .assertTextEquals("[00:00.50]Bright roan\n[00:02.00]We return")
            assertEquals(song.lyricsText, graph.store.song(id)!!.lyricsText)
            rule.onNodeWithContentDescription("Herramientas de letras con IA").performClick()
            rule.onNodeWithText("Reparar con IA").performClick()
            rule.onNodeWithText("Analizar").performClick()
            rule.waitUntil(10000) { model.lyricsAI.state.value?.review != null }
            assertTrue(model.lyricsAI.state.value!!.cached)
            rule.onNodeWithText("Seleccionar sugerencias").performClick()
            rule.onNodeWithText("Vista previa").performClick()
            rule.onNodeWithText("Usar en el editor").performClick()
            rule
                .onNodeWithTag("lyricsTextInput")
                .assertTextContains("Bright road", substring = true)
            assertEquals(song.lyricsText, graph.store.song(id)!!.lyricsText)
            rule.onNodeWithText("Guardar", useUnmergedTree = true).performClick()
            rule.waitUntil(5000) { graph.store.song(id)!!.lyricsText.contains("Bright road") }
            assertTrue(LyricsDocument.parse(graph.store.song(id)!!.lyricsText).isAIRepaired)
            assertEquals(original, contentDigest(file.readBytes()))
            assertNull(failure.get())
            assertEquals(2, requests.get())
        } finally {
            released.countDown()
            rule.runOnUiThread {
                graph.online.value = prior
                model.lyricsAI.close()
                model.closeLyricsEditor()
                model.controller?.stop()
                model.controller?.clearMediaItems()
            }
            server.shutdown()
            graph.store.removeSongs(listOf(id))
            runBlocking { graph.refresh() }
            file.delete()
        }
    }

    private fun screenshot(name: String) {
        rule.waitForIdle()
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(rule.activity.cacheDir, "qa-$name-${image.width}x${image.height}.png")
            .outputStream()
            .use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
