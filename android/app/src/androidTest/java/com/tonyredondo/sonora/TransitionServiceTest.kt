package com.tonyredondo.sonora

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class TransitionServiceTest {
    @Test
    fun sessionHandoffRetainsShuffleSpeedPauseSeekAndEndOfTrackTimer() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val graph = (context.applicationContext as SonoraApplication).graph
        withTimeout(5000) { while (!graph.ready.value) delay(25) }
        val root =
            File(context.cacheDir, "transition-service-${UUID.randomUUID()}").apply { mkdirs() }
        val original = graph.transitions.value
        val originalSound = graph.sound.value
        var controller: MediaController? = null
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            val file = File(root, "source.wav")
            InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use {
                input ->
                file.outputStream().use(input::copyTo)
            }
            // Repeating the synthetic fixture provides four independent eight-second references.
            val source =
                CueSegment("file:///qa-transition.cue", 1, 0, 600)
                    .applyTo(LocalAudio(context).read(Uri.fromFile(file)))
            val songs =
                (0..3).map { index ->
                    source.copy(
                        id = contentDigest("${file.path}:$index"),
                        title = "Transition QA $index",
                    )
                }
            graph.store.saveSongs(songs, inLibrary = false)
            val future =
                withContext(Dispatchers.Main) {
                    MediaController.Builder(
                            context,
                            SessionToken(
                                context,
                                ComponentName(context, PlaybackService::class.java),
                            ),
                        )
                        .buildAsync()
                }
            controller = future.get(10, TimeUnit.SECONDS)
            val player = controller
            withContext(Dispatchers.Main) {
                graph.loop.value = null
                graph.setSleepTimer(null)
                graph.setTransitions(TransitionSettings(TransitionMode.CROSSFADE, 2))
                graph.setSound(SoundSettings(1.25f, 1.05f))
                player.setMediaItems(songs.map { it.mediaItem() })
                player.shuffleModeEnabled = true
                player.repeatMode = Player.REPEAT_MODE_ALL
                player.prepare()
                player.play()
            }
            suspend fun until(check: () -> Boolean) {
                withTimeout(12000) { while (!withContext(Dispatchers.Main) { check() }) delay(30) }
            }
            until { player.isPlaying && player.currentPosition > 100 }
            val target = withContext(Dispatchers.Main) { player.nextMediaItemIndex }
            until { graph.transitionInfo.value == "Crossfade" }
            withContext(Dispatchers.Main) { player.pause() }
            delay(150)
            val paused = withContext(Dispatchers.Main) { player.currentPosition }
            delay(300)
            withContext(Dispatchers.Main) {
                assertEquals(paused, player.currentPosition)
                player.play()
            }
            until { player.currentMediaItemIndex == target && player.currentPosition > 200 }
            withContext(Dispatchers.Main) {
                assertTrue(player.shuffleModeEnabled)
                assertEquals(Player.REPEAT_MODE_ALL, player.repeatMode)
                assertEquals(1.25f, player.playbackParameters.speed, 0f)
                assertEquals(1.05f, player.playbackParameters.pitch, 0f)
                assertTrue(
                    "Handoff must retain the already-heard intro",
                    player.currentPosition > 1000,
                )
                player.seekTo(100)
                graph.setSleepTimer(
                    SleepTimer.endOfTrack(
                        player.currentMediaItem!!.mediaId,
                        player.currentMediaItemIndex,
                    ),
                )
            }
            until { !player.playWhenReady && player.currentPosition >= player.duration - 50 }
            withContext(Dispatchers.Main) {
                assertEquals(target, player.currentMediaItemIndex)
                assertNull(graph.sleepTimer.value)
                player.repeatMode = Player.REPEAT_MODE_ONE
                player.seekTo(6000)
                player.play()
            }
            until { player.isPlaying && player.currentPosition < 1500 }
            withContext(Dispatchers.Main) {
                assertEquals(target, player.currentMediaItemIndex)
                player.repeatMode = Player.REPEAT_MODE_OFF
                player.seekTo(6500)
                graph.loop.value = LoopRegion(player.currentMediaItem!!.mediaId, 6500, 7500)
            }
            delay(2500)
            withContext(Dispatchers.Main) {
                assertEquals(target, player.currentMediaItemIndex)
                assertTrue(player.currentPosition in 6500..7550)
            }
        } finally {
            withContext(Dispatchers.Main) {
                controller?.stop()
                controller?.clearMediaItems()
                controller?.release()
                graph.setTransitions(original)
                graph.setSound(originalSound)
                graph.setSleepTimer(null)
                graph.loop.value = null
            }
            scenario.close()
            root.deleteRecursively()
        }
    }
}
