package com.tonyredondo.sonora

import android.net.Uri
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Host-driven seed / force-stop (data preserved) / verify / cleanup on an owned emulator only. */
class ColdPlaybackRecoveryTest {
    @Test
    fun persistentTimerAndPausedQueueSurviveTheWholeProcess() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val phase = args.getString("sonora_timer_phase")
        assumeTrue("Requires a host-driven owned-emulator cold restart", phase != null)
        require(phase in listOf("seed", "verify", "cleanup"))
        val id = requireNotNull(args.getString("sonora_timer_fixture_id"))
        require(id.matches(Regex("cold-timer-qa-[a-f0-9-]{36}")))
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val file = File(app.cacheDir, "$id.wav")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (phase == "seed") {
            if (!file.exists())
                instrumentation.context.assets.open("fixture.wav").use { input ->
                    file.outputStream().use(input::copyTo)
                }
            graph.store.saveSongs(
                listOf(
                    Song(
                        id,
                        Uri.fromFile(file).toString(),
                        "Cold timer QA",
                        durationMs = 30000,
                        size = file.length(),
                        modified = file.lastModified(),
                    ),
                ),
                inLibrary = false,
            )
        }
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
            when (phase) {
                "seed" -> {
                    main { model.play(listOf(graph.store.song(id)!!)) }
                    until { model.controller!!.isPlaying }
                    val timer = SleepTimer.endOfTrack(id, 0)
                    main {
                        model.controller!!.pause()
                        graph.setSleepTimer(timer)
                    }
                    withTimeout(5000) {
                        while (
                            graph.store.state("sleep-v1") != timer.encode() ||
                                graph.store.snapshot()?.currentId != id
                        ) delay(20)
                    }
                    assertEquals(timer, graph.sleepTimer.value)
                }
                "verify" -> {
                    until { model.controller!!.currentMediaItem?.mediaId == id }
                    main { assertFalse(model.controller!!.playWhenReady) }
                    assertEquals(SleepTimer.endOfTrack(id, 0), graph.sleepTimer.value)
                    assertEquals(
                        SleepTimer.endOfTrack(id, 0).encode(),
                        graph.store.state("sleep-v1"),
                    )
                }
                "cleanup" -> {
                    main {
                        graph.setSleepTimer(null)
                        model.controller!!.stop()
                        model.controller!!.clearMediaItems()
                    }
                    withTimeout(5000) {
                        while (
                            graph.store.snapshot()?.ids?.isNotEmpty() == true ||
                                graph.store.state("sleep-v1") != "null"
                        ) delay(20)
                    }
                    graph.store.removeSongs(listOf(id))
                    file.delete()
                }
            }
        } finally {
            scenario.close()
        }
    }
}
