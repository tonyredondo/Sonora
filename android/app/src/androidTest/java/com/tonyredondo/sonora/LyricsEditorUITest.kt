package com.tonyredondo.sonora

import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LyricsEditorUITest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun editorSavesWholeLyricsAndKeepsTheFinalPhraseReadableWithoutKeyboardButtons() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val id = "editor-ui-${UUID.randomUUID()}"
        val title = "Editor QA $id"
        val file = File(rule.activity.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val source =
            Song(
                id,
                Uri.fromFile(file).toString(),
                title,
                "Sonora Tests",
                durationMs = 30000,
                lyricsText = "[00:01]First phrase\n[00:10]Old final phrase",
                size = file.length(),
                modified = file.lastModified(),
            )
        val replacement =
            "[00:01]First complete edited phrase\n[00:10]The complete final edited phrase is fully visible"
        try {
            graph.store.saveSongs(listOf(source))
            runBlocking { graph.refresh() }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(title))
            rule.onNodeWithText(title).performClick()
            rule.onNodeWithTag("page:LYRICS").performClick()
            rule.onNodeWithContentDescription("Ampliar vista").performClick()
            rule.onNodeWithContentDescription("Editar letra").performClick()
            rule.onNodeWithTag("lyricsTextInput").performClick().assertIsFocused()
            rule.onNodeWithTag("lyricsTextInput").performTextReplacement(replacement)
            screenshot("editor")
            rule.onNodeWithText("Los cambios se guardan en Sonora.").performTouchInput { click() }
            rule.onNodeWithTag("lyricsTextInput").assertIsNotFocused()
            rule.activityRule.scenario.recreate()
            rule.onNodeWithTag("lyricsTextInput").assertTextContains(replacement)
            rule.onAllNodesWithContentDescription("Ocultar teclado").assertCountEquals(0)
            rule.onNodeWithText("Guardar", useUnmergedTree = true).performClick()
            val model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
            rule.waitUntil(5000) { model.currentSong.value?.lyricsText == replacement }
            rule
                .onNodeWithTag("expandedLyricsList")
                .performScrollToNode(hasText("The complete final edited phrase is fully visible"))
            rule
                .onNode(
                    hasText("The complete final edited phrase is fully visible") and
                        hasAnyAncestor(hasTestTag("expandedLyricsList")),
                )
                .assertIsDisplayed()
            assertEquals(replacement, graph.store.song(id)?.lyricsText)
            screenshot("expanded")
            rule.onNodeWithText("Listo").performClick()
        } finally {
            rule.runOnUiThread {
                ViewModelProvider(rule.activity)[PlayerModel::class.java].controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(id))
            runBlocking { graph.refresh() }
            file.delete()
        }
    }

    @Test
    fun manualTimingOnlyChangesTheDraftUntilExplicitSaveAndCancelPreservesTheOriginal() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val id = "timing-ui-${UUID.randomUUID()}"
        val file = File(rule.activity.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val source =
            Song(
                id,
                Uri.fromFile(file).toString(),
                "Timing QA $id",
                durationMs = 30000,
                lyricsText = "A complete first phrase\nA complete final phrase",
                size = file.length(),
                modified = file.lastModified(),
            )
        val model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
        try {
            graph.store.saveSongs(listOf(source))
            runBlocking { graph.refresh() }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(source.title))
            rule.onNodeWithText(source.title).performClick()
            rule.waitUntil(5000) { model.playback.value.playing }
            rule.runOnUiThread {
                model.controller!!.pause()
                model.openManualTiming(source)
            }
            rule.runOnUiThread { model.seek(1000) }
            rule.onNodeWithTag("stampPhrase").performClick()
            rule.runOnUiThread { model.seek(4000) }
            rule.onNodeWithTag("stampPhrase").performClick()
            rule.onNodeWithText("Usar en el borrador").performClick()
            assertEquals(source.lyricsText, graph.store.song(id)?.lyricsText)
            assertEquals(
                listOf(1000L, 4000L),
                LyricsDocument.parse(model.lyricsEditorText.value).lines.map { it.timeMs },
            )
            rule.onNodeWithText("Cancelar").performClick()
            rule.onNodeWithText("Seguir editando").performClick()
            rule.onNodeWithText("Guardar", useUnmergedTree = true).performClick()
            rule.waitUntil(5000) {
                graph.store.song(id)?.lyricsText?.startsWith("[00:01.00]") == true
            }
            val saved = graph.store.song(id)!!
            rule.runOnUiThread { model.editLyrics(saved) }
            rule.onNodeWithTag("lyricsTextInput").performTextReplacement("Unsaved replacement")
            rule.onNodeWithText("Cancelar").performClick()
            rule.onNodeWithText("Descartar", useUnmergedTree = true).performClick()
            assertEquals(saved.lyricsText, graph.store.song(id)?.lyricsText)
        } finally {
            rule.runOnUiThread {
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(id))
            runBlocking { graph.refresh() }
            file.delete()
        }
    }

    @Test
    fun markersSeekAndDeleteFromSoundOptionsAndFollowCanBeDisabled() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val id = "markers-ui-${UUID.randomUUID()}"
        val file = File(rule.activity.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val song =
            Song(
                id,
                Uri.fromFile(file).toString(),
                "Markers QA $id",
                durationMs = 30000,
                lyricsText = "[00:01]First phrase\n[00:10]Final phrase",
                size = file.length(),
                modified = file.lastModified(),
            )
        val model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
        try {
            graph.store.saveSongs(listOf(song))
            runBlocking { graph.refresh() }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(song.title))
            rule.onNodeWithText(song.title).performClick()
            rule.waitUntil(5000) { model.playback.value.playing }
            rule.runOnUiThread {
                model.controller!!.pause()
                model.seek(3500)
            }
            rule.onNodeWithContentDescription("Sonido").performClick()
            rule.onNodeWithText("BPM y marcadores").performClick()
            rule
                .onNode(hasSetTextAction() and hasText("Nombre del marcador"))
                .performTextInput("Estribillo")
            rule.onNode(hasText("Añadir en", substring = true)).performClick()
            rule.waitUntil(5000) { graph.songTools.value[id]?.markers?.size == 1 }
            rule.onNode(hasSetTextAction() and hasText("Nombre del marcador")).assertIsNotFocused()
            rule.onNodeWithText("Estribillo").assertIsDisplayed()
            rule.runOnUiThread { model.seek(1000) }
            rule.onNodeWithText("Estribillo").performClick()
            rule.runOnIdle { assertEquals(3500L, model.controller!!.currentPosition) }
            screenshot("markers")
            rule.onNodeWithContentDescription("Eliminar Estribillo").performClick()
            rule.waitUntil(5000) { graph.songTools.value[id]?.markers?.isEmpty() == true }
            rule.onNodeWithText("Listo").performClick()
            rule.onNodeWithTag("page:LYRICS").performClick()
            rule.onNodeWithContentDescription("Ampliar vista").performClick()
            rule.onNodeWithContentDescription("Seguir canción").performClick()
            rule.runOnIdle { assertFalse(model.followLyrics.value) }
            rule.onNodeWithContentDescription("Seguir canción").performClick()
            rule.runOnIdle { assertTrue(model.followLyrics.value) }
            rule.onNodeWithText("Listo").performClick()
        } finally {
            rule.runOnUiThread {
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(id))
            runBlocking { graph.refresh() }
            file.delete()
        }
    }

    private fun screenshot(name: String) {
        rule.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(rule.activity.cacheDir, "qa-$name-${bitmap.width}x${bitmap.height}.png")
            .outputStream()
            .use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
        bitmap.recycle()
    }
}
