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

class ListeningUITest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun soundControlsOfferTheSamePresetsBalanceNormalizationAndTimersInBothLayouts() {
        val graph = (rule.activity.application as SonoraApplication).graph
        rule.waitUntil(5000) { graph.ready.value }
        val prior = graph.listening.value
        val priorTransitions = graph.transitions.value
        val id = "sound-ui-${UUID.randomUUID()}"
        val file = File(rule.activity.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val song = Song(id, Uri.fromFile(file).toString(), "Sonido QA", durationMs = 30000)
        val model = ViewModelProvider(rule.activity)[PlayerModel::class.java]
        try {
            graph.store.saveSongs(listOf(song))
            runBlocking { graph.refresh() }
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Sonido QA"))
            rule.onNodeWithText("Sonido QA").performClick()
            rule.onNodeWithContentDescription("Sonido").performClick()
            rule.onNodeWithText("Ecualizador").performClick()
            rule
                .onNode(
                    SemanticsMatcher.keyIsDefined(
                        androidx.compose.ui.semantics.SemanticsProperties.HorizontalScrollAxisRange,
                    ) and hasAnyDescendant(hasText("Plano")),
                )
                .performScrollToNode(hasText("Rock"))
            rule.onNodeWithText("Rock", useUnmergedTree = true).performClick()
            rule.runOnIdle {
                assertEquals(EqualizerPreset.ROCK.settings(), graph.listening.value.equalizer)
            }
            rule
                .onNodeWithTag("soundBody")
                .performScrollToNode(hasContentDescription("Ganancia 1000 Hz"))
            rule.onNodeWithContentDescription("Ganancia 1000 Hz").assertIsDisplayed()
            screenshot("equalizer")
            rule.onNodeWithTag("soundTabs").performScrollToNode(hasText("Escucha"))
            rule.onNodeWithText("Escucha", useUnmergedTree = true).performClick()
            rule.onNodeWithContentDescription("Balance estéreo").performSemanticsAction(
                androidx.compose.ui.semantics.SemanticsActions.SetProgress,
            ) {
                it(.5f)
            }
            rule.runOnIdle { assertEquals(.5f, graph.listening.value.balance, .01f) }
            rule.onNodeWithText("Por canción", useUnmergedTree = true).performClick()
            rule.waitUntil(5000) { graph.listening.value.normalization == NormalizationMode.TRACK }
            rule.onNodeWithTag("soundTabs").performScrollToNode(hasText("Temporizador"))
            rule.onNodeWithText("Temporizador", useUnmergedTree = true).performClick()
            rule.onNodeWithText("15 min", useUnmergedTree = true).performClick()
            screenshot("timer")
            rule.runOnIdle { assertNotNull(graph.sleepTimer.value?.deadlineMs) }
            rule.onNodeWithTag("soundBody").performScrollToNode(hasText("Cancelar temporizador"))
            rule.onNodeWithText("Cancelar temporizador").performClick()
            rule.runOnIdle { assertNull(graph.sleepTimer.value) }
            rule.onNodeWithTag("soundTabs").performScrollToNode(hasText("Mezcla"))
            rule.onNodeWithText("Mezcla", useUnmergedTree = true).performClick()
            rule.onNodeWithText("Mezcla automática", useUnmergedTree = true).performClick()
            rule.onNodeWithContentDescription("Duración del fundido").performSemanticsAction(
                androidx.compose.ui.semantics.SemanticsActions.SetProgress,
            ) {
                it(7f)
            }
            rule.runOnIdle {
                assertEquals(
                    TransitionSettings(TransitionMode.ADAPTIVE, 7),
                    graph.transitions.value,
                )
            }
            rule.waitUntil(5000) {
                graph.store.state("transitions-v1")?.let { TransitionSettings.decode(it) } ==
                    graph.transitions.value
            }
            rule
                .onNodeWithTag("soundBody")
                .performScrollToNode(hasText("Alinea los golpes", substring = true))
            screenshot("transitions")
            rule.onNodeWithText("Listo").performClick()
        } finally {
            rule.runOnUiThread {
                graph.setListening(prior)
                graph.setTransitions(priorTransitions)
                graph.setSleepTimer(null)
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
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(rule.activity.cacheDir, "qa-$name-${image.width}x${image.height}.png")
            .outputStream()
            .use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
