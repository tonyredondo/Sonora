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

class ListeningServiceTest {
    @Test
    fun effectsPersistWhilePlayingAndBothTimersStopAudioOffscreen() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val oldListening = graph.listening.value
        val id = "listening-${UUID.randomUUID()}"
        val file = File(app.cacheDir, "$id.wav")
        instrumentation.context.assets.open("fixture.wav").use { input ->
            file.outputStream().use(input::copyTo)
        }
        val song = Song(id, Uri.fromFile(file).toString(), "Listening QA", durationMs = 30000)
        graph.store.saveSongs(listOf(song))
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var model: PlayerModel
        scenario.onActivity { model = ViewModelProvider(it)[PlayerModel::class.java] }
        fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
        suspend fun until(check: () -> Boolean) =
            withTimeout(6000) {
                while (true) {
                    var ok = false
                    main { ok = check() }
                    if (ok) break
                    delay(20)
                }
            }
        try {
            until { model.controller != null }
            main { model.play(listOf(song, song.copy(id = "$id-second"))) }
            until { model.controller!!.isPlaying }
            val value = ListeningSettings(EqualizerPreset.ROCK.settings(), .25f)
            main { graph.setListening(value) }
            withTimeout(5000) {
                while (graph.store.state("listening-v1") != value.encode()) delay(10)
            }
            LibraryStore(app).use {
                assertEquals(value, ListeningSettings.decode(it.state("listening-v1")!!))
            }
            until { model.controller!!.currentPosition > 200 }
            instrumentation.uiAutomation.executeShellCommand("input keyevent 3").close()
            val timer = SleepTimer.deadline(System.currentTimeMillis() + 2000)
            main { graph.setSleepTimer(timer) }
            withTimeout(1500) { while (graph.store.state("sleep-v1") != timer.encode()) delay(10) }
            LibraryStore(app).use { assertEquals(timer, SleepTimer.decode(it.state("sleep-v1")!!)) }
            until { !model.controller!!.playWhenReady && graph.sleepTimer.value == null }
            main {
                model.controller!!.seekTo(0, 29200)
                graph.setSleepTimer(SleepTimer.endOfTrack(id, 0))
                model.controller!!.repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
                model.controller!!.play()
            }
            until { !model.controller!!.playWhenReady && graph.sleepTimer.value == null }
            var before = 0L
            main { before = model.controller!!.currentPosition }
            delay(250)
            main { assertEquals(before, model.controller!!.currentPosition) }
            main {
                model.controller!!.repeatMode = androidx.media3.common.Player.REPEAT_MODE_OFF
                model.controller!!.seekTo(0, 0)
                model.controller!!.play()
            }
            until { model.controller!!.isPlaying && model.controller!!.currentPosition > 100 }
        } finally {
            main {
                graph.setListening(oldListening)
                graph.setSleepTimer(null)
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(listOf(id, "$id-second"))
            file.delete()
            scenario.close()
        }
    }
}
