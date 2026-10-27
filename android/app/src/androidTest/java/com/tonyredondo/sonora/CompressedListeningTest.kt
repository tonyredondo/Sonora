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

class CompressedListeningTest {
    @Test
    fun mp3DecodesThroughEffectsAndSonicWhileKeepingReplayGainAndTheSourceUnchanged() =
        runBlocking {
            val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
            val graph = app.graph
            withTimeout(5000) { while (!graph.ready.value) delay(10) }
            val prior = graph.listening.value
            val sound = graph.sound.value
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val file = File(app.cacheDir, "compressed-${UUID.randomUUID()}.mp3")
            instrumentation.context.assets.open("replaygain.mp3").use { input ->
                file.outputStream().use(input::copyTo)
            }
            val original = contentDigest(file.readBytes())
            val song = LocalAudio(app).read(Uri.fromFile(file))
            graph.store.saveSongs(listOf(song), inLibrary = false)
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
                main {
                    graph.setListening(
                        ListeningSettings(
                            EqualizerPreset.ROCK.settings(),
                            .2f,
                            NormalizationMode.TRACK,
                        ),
                    )
                    graph.setSound(SoundSettings(.8f, 1.5f))
                    model.play(listOf(song))
                }
                until {
                    model.controller!!.isPlaying &&
                        model.controller!!.currentPosition > 300 &&
                        graph.normalizationInfo.value.startsWith("ReplayGain")
                }
                main {
                    assertNull(model.controller!!.playerError)
                    assertEquals(.8f, model.controller!!.playbackParameters.speed, 0f)
                    assertEquals(1.5f, model.controller!!.playbackParameters.pitch, 0f)
                }
                assertEquals(original, contentDigest(file.readBytes()))
            } finally {
                main {
                    graph.setListening(prior)
                    graph.setSound(sound)
                    model.controller?.apply {
                        stop()
                        clearMediaItems()
                    }
                }
                graph.store.removeSongs(listOf(song.id))
                file.delete()
                scenario.close()
            }
        }
}
