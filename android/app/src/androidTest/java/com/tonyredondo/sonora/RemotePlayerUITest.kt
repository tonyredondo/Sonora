package com.tonyredondo.sonora

import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemotePlayerUITest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun preparingMessagesAreReplacedByCompleteContentOnTheCurrentCarouselPage() {
        val graph = (rule.activity.application as SonoraApplication).graph
        val oldSettings = graph.online.value
        val id = "remote-ui-${UUID.randomUUID()}"
        val file = File(rule.activity.cacheDir, "$id.wav")
        val release = CountDownLatch(1)
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
                            .setBody("{\"error\":\"disabled\"}")
                    if (path == "/v1/audio/character")
                        return MockResponse()
                            .setBody(
                                """{"version":"essentia-discogs-v1","silent":true,"styles":[],"moods":{"happy":0,"sad":0,"relaxed":0,"aggressive":0}}""",
                            )
                    val input = JSONObject(request.body.readUtf8())
                    if (input.toString().contains(id)) check(release.await(8, TimeUnit.SECONDS))
                    val value =
                        if (path == "/v1/lyrics/translate")
                            JSONObject()
                                .put("model", "gpt-6.1-sol")
                                .put("effort", "medium")
                                .put(
                                    "lines",
                                    JSONArray()
                                        .put(
                                            JSONObject()
                                                .put("id", 0)
                                                .put("text", "La primera frase traducida."),
                                        )
                                        .put(
                                            JSONObject()
                                                .put("id", 1)
                                                .put("text", "La última frase traducida."),
                                        ),
                                )
                        else
                            JSONObject()
                                .put("model", "gpt-6-astra")
                                .put("effort", "medium")
                                .put("explanation", "La explicación completa de QA.")
                    return MockResponse().setBody(value.toString())
                }
            }
        server.start()
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use {
                source ->
                file.outputStream().use(source::copyTo)
            }
            graph.store.saveSongs(
                listOf(
                    Song(
                        id,
                        Uri.fromFile(file).toString(),
                        "Remote UI QA",
                        "Sonora Tests",
                        "Online QA",
                        durationMs = 30000,
                        lyricsText =
                            "[00:00]First source phrase $id\n[00:20]The final source phrase",
                    ),
                ),
            )
            runBlocking { graph.refresh() }
            val connection = OnlineSettings(server.url("/").toString())
            rule.runOnUiThread { graph.online.value = connection }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Remote UI QA"))
            rule.onNodeWithText("Remote UI QA").performClick()
            rule.onNodeWithTag("page:MEANING").performClick()
            try {
                rule.waitUntil(5000) {
                    graph.extras.value[id]?.progress?.get(PreparationStage.MEANING)?.state ==
                        PreparationState.RUNNING
                }
            } catch (error: androidx.compose.ui.test.ComposeTimeoutException) {
                throw AssertionError(
                    "Preparation stages: ${graph.extras.value[id]?.progress}; audioPending=${graph.preparation.pending(id)}; tagsPending=${graph.character.pending(id)}",
                    error,
                )
            }
            rule.onNodeWithText("Preparando información de la canción…").assertIsDisplayed()
            release.countDown()
            rule.waitUntil(10000) { graph.extras.value[id]?.meaning != null }
            rule.onNodeWithText("La explicación completa de QA.").assertIsDisplayed()
            rule.onNodeWithText("Preparando información de la canción…").assertDoesNotExist()
            rule.onNodeWithTag("page:TRANSLATION").performClick()
            rule.onNodeWithTag("lyricsList").performScrollToNode(hasTestTag("lyric:1"))
            rule.onNodeWithText("La última frase traducida.").assertIsDisplayed()
        } finally {
            release.countDown()
            rule.runOnUiThread {
                val player = ViewModelProvider(rule.activity)[PlayerModel::class.java].controller
                player?.stop()
                player?.clearMediaItems()
                graph.online.value = oldSettings
            }
            graph.store.removeSongs(listOf(id))
            runBlocking { graph.refresh() }
            file.delete()
            server.shutdown()
        }
    }
}
