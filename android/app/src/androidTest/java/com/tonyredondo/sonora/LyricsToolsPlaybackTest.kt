package com.tonyredondo.sonora

import android.net.Uri
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LyricsToolsPlaybackTest {
    @Test
    fun phraseLoopsOffscreenMarkersSurviveReopenAndChangingSongStopsTheLoop() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val id = "phrase-loop-${UUID.randomUUID()}"
        val file = File(app.cacheDir, "$id.wav")
        instrumentation.context.assets.open("fixture.wav").use { input ->
            file.outputStream().use(input::copyTo)
        }
        val song = Song(id, Uri.fromFile(file).toString(), "Phrase loop QA", durationMs = 30000)
        graph.store.saveSongs(listOf(song))
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var model: PlayerModel
        scenario.onActivity { model = ViewModelProvider(it)[PlayerModel::class.java] }
        fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
        suspend fun until(check: () -> Boolean) =
            withTimeout(5000) {
                while (true) {
                    var result = false
                    main { result = check() }
                    if (result) break
                    delay(20)
                }
            }
        val sound = graph.sound.value
        try {
            until { model.controller != null }
            main {
                graph.setSound(SoundSettings())
                model.play(listOf(song))
            }
            until { model.controller?.isPlaying == true }
            val tools = SongTools(350, listOf(SongMarker("chorus", "Estribillo", 550)))
            main {
                graph.setSongTools(id, tools)
                graph.loop.value = LoopRegion(id, 500, 1000)
                model.controller!!.seekTo(500)
            }
            withTimeout(5000) {
                while (graph.store.state("song-tools-v1:$id") != tools.encode()) delay(10)
            }
            LibraryStore(app).use { reopened ->
                assertEquals(tools, SongTools.decode(reopened.state("song-tools-v1:$id")!!))
            }
            instrumentation.uiAutomation.executeShellCommand("input keyevent 3").close()
            var last = 500L
            var wraps = 0
            withTimeout(5000) {
                while (wraps < 2) {
                    var position = 0L
                    main { position = model.controller!!.currentPosition }
                    if (last - position > 250) wraps++
                    last = position
                    delay(30)
                }
            }
            main {
                model.controller!!.setMediaItem(song.copy(id = "$id-next").mediaItem())
                model.controller!!.prepare()
            }
            until { graph.loop.value == null }
        } finally {
            main {
                graph.loop.value = null
                graph.setSound(sound)
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(id, "$id-next"))
            file.delete()
            scenario.close()
        }
    }
}
