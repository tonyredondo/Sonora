package com.tonyredondo.sonora

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.sin
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlaybackServiceTest {
    @Test
    fun audioKeepsAdvancingOffscreenAndRecoversAfterAnUnreadableFile() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file =
            File(context.cacheDir, "qa-${UUID.randomUUID()}.wav").apply { writeBytes(tone()) }
        val broken = File(context.cacheDir, "qa-${UUID.randomUUID()}.wav")
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val controller =
            MediaController.Builder(
                    context,
                    SessionToken(context, ComponentName(context, PlaybackService::class.java)),
                )
                .setApplicationLooper(Looper.getMainLooper())
                .buildAsync()
                .get(10, TimeUnit.SECONDS)
        fun main(action: () -> Unit) =
            InstrumentationRegistry.getInstrumentation().runOnMainSync(action)
        fun until(check: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (true) {
                var ready = false
                main { ready = check() }
                if (ready) return
                kotlin.check(System.nanoTime() < deadline) { "Playback condition timed out" }
                Thread.sleep(50)
            }
        }
        try {
            main {
                controller.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
                controller.prepare()
                controller.play()
            }
            until { controller.isPlaying && controller.currentPosition > 250 }
            val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
            automation.executeShellCommand("input keyevent 3").close()
            var before = 0L
            main { before = controller.currentPosition }
            until { controller.currentPosition > before + 250 }
            main {
                controller.pause()
                controller.setMediaItem(MediaItem.fromUri(Uri.fromFile(broken)))
                controller.prepare()
                controller.play()
            }
            until { controller.playerError != null }
            broken.writeBytes(tone())
            main {
                controller.prepare()
                controller.play()
            }
            until {
                controller.playerError == null &&
                    controller.isPlaying &&
                    controller.currentPosition > 150
            }
            main {
                controller.repeatMode = Player.REPEAT_MODE_ALL
                controller.shuffleModeEnabled = true
                assertEquals(Player.REPEAT_MODE_ALL, controller.repeatMode)
                assertTrue(controller.shuffleModeEnabled)
                controller.pause()
                assertFalse(controller.playWhenReady)
            }
        } finally {
            main {
                controller.stop()
                controller.clearMediaItems()
                controller.release()
            }
            scenario.close()
            file.delete()
            broken.delete()
        }
    }

    @Test
    fun tappingPlayAfterTransientFocusLossRequestsAudioAgain() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file =
            File(context.cacheDir, "focus-qa-${UUID.randomUUID()}.wav").apply { writeBytes(tone()) }
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var model: PlayerModel
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val focus =
            android.media.AudioFocusRequest.Builder(
                    android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                )
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener({ _ -> }, android.os.Handler(Looper.getMainLooper()))
                .build()
        fun main(action: () -> Unit) =
            InstrumentationRegistry.getInstrumentation().runOnMainSync(action)
        fun until(check: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (true) {
                var ready = false
                main { ready = check() }
                if (ready) return
                check(System.nanoTime() < deadline) { "Focus recovery condition timed out" }
                Thread.sleep(20)
            }
        }
        try {
            scenario.onActivity {
                model = androidx.lifecycle.ViewModelProvider(it)[PlayerModel::class.java]
            }
            until { model.controller != null }
            main { model.play(listOf(Song("focus-qa", Uri.fromFile(file).toString(), "Focus QA"))) }
            until { model.controller?.isPlaying == true }
            main {
                assertEquals(
                    android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED,
                    audio.requestAudioFocus(focus),
                )
            }
            until {
                model.controller?.playWhenReady == true &&
                    model.controller?.playbackSuppressionReason ==
                        Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
            }
            main { model.togglePlayback() }
            until { model.controller?.isPlaying == true }
        } finally {
            main {
                audio.abandonAudioFocusRequest(focus)
                model.controller?.stop()
                model.controller?.clearMediaItems()
            }
            scenario.close()
            file.delete()
        }
    }

    private fun tone(): ByteArray {
        val rate = 44100
        val frames = rate * 20
        val output = ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN)
        output.put("RIFF".toByteArray())
        output.putInt(36 + frames * 2)
        output.put("WAVEfmt ".toByteArray())
        output.putInt(16)
        output.putShort(1)
        output.putShort(1)
        output.putInt(rate)
        output.putInt(rate * 2)
        output.putShort(2)
        output.putShort(16)
        output.put("data".toByteArray())
        output.putInt(frames * 2)
        repeat(frames) {
            output.putShort((sin(it * 2 * Math.PI * 440 / rate) * 8192).toInt().toShort())
        }
        return output.array()
    }
}
