package com.tonyredondo.sonora

import android.content.ComponentName
import android.os.Looper
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SoundPersistenceTest {
    @Test
    fun settingsReachThePlayerAndSurviveDatabaseReopen() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val previous = graph.sound.value
        val value = SoundSettings(.8f, 1.5f)
        fun main(action: () -> Unit) =
            InstrumentationRegistry.getInstrumentation().runOnMainSync(action)
        lateinit var future: com.google.common.util.concurrent.ListenableFuture<MediaController>
        main {
            future =
                MediaController.Builder(
                        app,
                        SessionToken(app, ComponentName(app, PlaybackService::class.java)),
                    )
                    .setApplicationLooper(Looper.getMainLooper())
                    .buildAsync()
        }
        val controller = future.get(10, TimeUnit.SECONDS)
        try {
            main { graph.setSound(value) }
            withTimeout(5000) {
                while (true) {
                    var applied = false
                    main {
                        applied =
                            controller.playbackParameters.speed == .8f &&
                                controller.playbackParameters.pitch == 1.5f
                    }
                    if (applied && graph.store.state("sound-v1") == value.encode()) break
                    delay(10)
                }
            }
            val reopened = LibraryStore(app)
            try {
                assertEquals(value, SoundSettings.decode(reopened.state("sound-v1")!!))
            } finally {
                reopened.close()
            }
        } finally {
            main {
                graph.setSound(previous)
                MediaController.releaseFuture(future)
            }
            withTimeout(5000) {
                while (graph.store.state("sound-v1") != previous.encode()) delay(10)
            }
        }
    }
}
