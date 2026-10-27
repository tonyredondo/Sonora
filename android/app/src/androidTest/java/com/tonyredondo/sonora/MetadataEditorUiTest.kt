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

class MetadataEditorUiTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun explicitSaveAndDiscardWorkInBothLayouts() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val file = File(rule.activity.cacheDir, "metadata-ui-${UUID.randomUUID()}.mp3")
        InstrumentationRegistry.getInstrumentation().context.assets.open("replaygain.mp3").use {
            input ->
            file.outputStream().use(input::copyTo)
        }
        val bytes = file.readBytes()
        val song = graph.reader.read(Uri.fromFile(file)).copy(title = "Metadata UI QA")
        val model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
        try {
            graph.store.saveSongs(listOf(song))
            runBlocking { graph.refresh() }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(song.title))
            rule.onNodeWithTag("metadata:${song.id}").performClick()
            rule.onNodeWithText("Título").performTextReplacement("Edited metadata")
            rule.activityRule.scenario.recreate()
            rule.onNodeWithText("Edited metadata").assertExists()
            rule
                .onNodeWithText(
                    "Los cambios se guardan en Sonora y se incluyen al exportar. El archivo de origen se conserva.",
                )
                .performClick()
            rule.onNodeWithText("Título").assertIsNotFocused()
            rule.waitForIdle()
            // Let the system IME finish its independent dismissal before the visual capture.
            android.os.SystemClock.sleep(600)
            val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            File(rule.activity.cacheDir, "qa-metadata-${image.width}x${image.height}.png")
                .outputStream()
                .use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
            rule.onNodeWithText("Guardar en Sonora").performClick()
            rule.waitUntil(5000) {
                graph.songs.value.any { it.id == song.id && it.title == "Edited metadata" }
            }
            assertArrayEquals(bytes, file.readBytes())
            // Saving a new title changes sort position; reveal the same fixture again.
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Edited metadata"))
            rule.onNodeWithTag("metadata:${song.id}").performClick()
            rule.onNodeWithText("Título").performTextReplacement("Discarded title")
            rule.onNodeWithText("Título").performImeAction()
            rule.onNodeWithText("Cancelar").performClick()
            rule.onNodeWithText("Descartar", useUnmergedTree = true).performClick()
            assertEquals("Edited metadata", graph.store.song(song.id)!!.title)
        } finally {
            rule.runOnUiThread {
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(song.id))
            runBlocking { graph.refresh() }
            file.delete()
        }
    }
}
