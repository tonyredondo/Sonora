package com.tonyredondo.sonora

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AdaptivePlayerTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test
    fun adaptsPlayerAndKeepsTheSelectedPageAcrossSongs() {
        val graph = (rule.activity.application as SonoraApplication).graph
        val playlistLabel = "QA list ${java.util.UUID.randomUUID()}"
        val ids = listOf("qa-layout-one", "qa-layout-two")
        val sound =
            File(rule.activity.cacheDir, "qa-layout.wav").apply {
                androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("fixture.wav")
                    .use { source -> outputStream().use(source::copyTo) }
            }
        val cover =
            File(rule.activity.cacheDir, "qa-layout-cover.png").apply {
                androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
                    .context
                    .assets
                    .open("cover.png")
                    .use { source -> outputStream().use(source::copyTo) }
            }
        try {
            graph.store.saveSongs(
                ids.mapIndexed { index, id ->
                    Song(
                        id,
                        Uri.fromFile(sound).toString(),
                        "Layout QA $index",
                        "Sonora Tests",
                        "Landscape QA",
                        artworkPath = cover.absolutePath,
                        lyricsText =
                            "[00:00]First phrase\n[00:10]Middle phrase\n[00:20]The complete final phrase",
                    )
                },
            )
            runBlocking { graph.refresh() }
            rule.onNodeWithText("Listas").performClick()
            rule.onNodeWithText("Crear lista").performClick()
            rule.onNode(hasSetTextAction() and hasText("Nombre")).performTextInput(playlistLabel)
            rule.onNodeWithText("Crear").performClick()
            rule.waitUntil(5000) { graph.playlists.value.any { it.name == playlistLabel } }
            rule.onNodeWithText(playlistLabel).assertIsDisplayed()
            rule.onNodeWithText("Canciones").performClick()
            rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Layout QA 0"))
            rule.onNodeWithText("Layout QA 0").performClick()
            val portrait =
                rule.activity.resources.configuration.orientation ==
                    android.content.res.Configuration.ORIENTATION_PORTRAIT
            rule
                .onNodeWithTag(if (portrait) "playerPortrait" else "playerLandscape")
                .assertIsDisplayed()
            rule.onNodeWithTag("playerCarousel").assertIsDisplayed()
            rule.onNodeWithTag("page:ARTWORK").performClick()
            rule.runOnIdle { check(graph.page.value == PlayerPage.ARTWORK) }
            rule.onNodeWithContentDescription("Siguiente").performClick()
            rule.runOnIdle { check(graph.page.value == PlayerPage.ARTWORK) }
            rule.onNodeWithTag("page:LYRICS").performClick()
            rule.onNodeWithTag("lyricsList").performScrollToNode(hasTestTag("lyric:2"))
            rule.onNodeWithTag("lyricsList").performTouchInput { swipeUp() }
            rule.onNodeWithTag("lyric:2").assertIsDisplayed()
            val lyricBounds = rule.onNodeWithTag("lyric:2").fetchSemanticsNode().boundsInRoot
            val listBounds = rule.onNodeWithTag("lyricsList").fetchSemanticsNode().boundsInRoot
            check(lyricBounds.bottom < listBounds.bottom - listBounds.height * .20f) {
                "The final phrase must be readable above the fade."
            }
            rule.onRoot().captureToImage().asAndroidBitmap().let { image ->
                File(
                        rule.activity.getExternalFilesDir(null),
                        if (portrait) "portrait-qa.png" else "landscape-qa.png",
                    )
                    .outputStream()
                    .use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
            rule.onNodeWithTag("page:ARTWORK").performClick()
            rule.onNodeWithContentDescription("Ampliar vista").performClick()
            rule.onNodeWithText("Listo").assertIsDisplayed().performClick()
            rule.runOnIdle {
                val model =
                    androidx.lifecycle.ViewModelProvider(rule.activity)[PlayerModel::class.java]
                model.controller?.stop()
                model.controller?.clearMediaItems()
            }
        } finally {
            graph.store
                .playlists()
                .filter { it.name == playlistLabel }
                .forEach { graph.store.removePlaylist(it.id) }
            graph.store.removeSongs(ids)
            runBlocking { graph.refresh() }
            sound.delete()
            cover.delete()
        }
    }
}
