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

class NormalizationPreparationTest {
    @Test
    fun albumNormalizationMeasuresAndCachesOtherTracksWithoutUsingOnlineProviders() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val old = graph.listening.value
        val online = graph.online.value
        val server = okhttp3.mockwebserver.MockWebServer()
        server.dispatcher =
            object : okhttp3.mockwebserver.Dispatcher() {
                override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest) =
                    okhttp3.mockwebserver
                        .MockResponse()
                        .setResponseCode(503)
                        .setBody("{\"error\":\"disabled\"}")
            }
        server.start()
        val endpoint = server.url("/").toString()
        val group = UUID.randomUUID().toString()
        val files = List(2) { File(app.cacheDir, "normalization-$group-$it.wav") }
        val bytes = instrumentation.context.assets.open("fixture.wav").use { it.readBytes() }
        files.forEach { it.writeBytes(bytes) }
        val songs = files.mapIndexed { i, f ->
            Song(
                "normalization-$group-$i",
                Uri.fromFile(f).toString(),
                "Volume QA $i",
                "Sonora Tests",
                "Volume QA $group",
                durationMs = 30000,
                size = f.length(),
                modified = f.lastModified(),
            )
        }
        graph.store.saveSongs(songs)
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var model: PlayerModel
        scenario.onActivity { model = ViewModelProvider(it)[PlayerModel::class.java] }
        fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
        suspend fun until(check: () -> Boolean) =
            withTimeout(10000) {
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
                graph.online.value = OnlineSettings(endpoint, enabled = false)
                model.play(listOf(songs[0]))
                graph.setListening(ListeningSettings(normalization = NormalizationMode.ALBUM))
            }
            until {
                graph.normalizationInfo.value.startsWith("Análisis") &&
                    graph.extras.value[songs[1].id]?.volume != null
            }
            val measured = graph.extras.value[songs[1].id]!!.volume!!
            assertNull(graph.extras.value[songs[1].id]?.meaning)
            assertEquals(0, server.requestCount)
            files[1].delete()
            main { graph.extras.value = graph.extras.value - songs[1].id }
            until {
                graph.extras.value[songs[1].id]?.volume != null &&
                    graph.normalizationInfo.value.startsWith("Análisis")
            }
            assertEquals(measured, graph.extras.value[songs[1].id]?.volume)
            assertArrayEquals(bytes, files[0].readBytes())
        } finally {
            main {
                graph.setListening(old)
                graph.online.value = online
                model.controller?.apply {
                    stop()
                    clearMediaItems()
                }
            }
            graph.store.removeSongs(songs.map { it.id })
            files.forEach { it.delete() }
            scenario.close()
            server.shutdown()
        }
    }
}
