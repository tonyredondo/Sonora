package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.*
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class CrossfadeTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun unreadableIncomingFileDoesNotFadeTheHealthyTrackOrRetryEveryTick() = runBlocking {
        val root = File(context.cacheDir, "fade-failure-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.wav")
        tone(source, 220.0)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var player: ExoPlayer? = null
        var coordinator: CrossfadeCoordinator? = null
        var created = 0
        var message = ""
        try {
            withContext(Dispatchers.Main) {
                player = PlaybackPlayerFactory.create(context, ListeningAudioProcessor(), false)
                player!!.setMediaItems(
                    listOf(
                        LocalAudio(context).read(Uri.fromFile(source)).mediaItem(),
                        Song(
                                "missing",
                                Uri.fromFile(File(root, "missing.wav")).toString(),
                                "Missing",
                            )
                            .mediaItem(),
                    ),
                )
                player!!.prepare()
                player!!.play()
                coordinator =
                    CrossfadeCoordinator(
                        scope,
                        { player!! },
                        { TransitionSettings(TransitionMode.CROSSFADE, 3) },
                        { ListeningSettings() },
                        { false },
                        { false },
                        { MixTrack(ListeningSettings(), 1.0, SongExtras()) },
                        {
                            created++
                            PlaybackPlayerFactory.create(context, it, false)
                        },
                        { _, _ -> fail("An unreadable source cannot be handed off") },
                        { message = it },
                    )
            }
            withTimeout(7000) {
                while (
                    !withContext(Dispatchers.Main) {
                        message.startsWith("Continúa sin mezcla") && player!!.currentPosition > 2000
                    }
                ) delay(40)
            }
            withContext(Dispatchers.Main) {
                assertTrue(player!!.isPlaying)
                assertNull(player!!.playerError)
                assertEquals(1f, player!!.volume, 0f)
                assertEquals(1, created)
            }
        } finally {
            withContext(Dispatchers.Main) {
                coordinator?.close()
                player?.release()
            }
            scope.cancel()
            root.deleteRecursively()
        }
    }

    private fun tone(file: File, frequency: Double) {
        val samples = 16000 * 8
        val out = ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN)
        out.put("RIFF".toByteArray())
            .putInt(36 + samples * 2)
            .put("WAVEfmt ".toByteArray())
            .putInt(16)
            .putShort(1)
            .putShort(1)
            .putInt(16000)
            .putInt(32000)
            .putShort(2)
            .putShort(16)
            .put("data".toByteArray())
            .putInt(samples * 2)
        repeat(samples) {
            out.putShort((sin(2 * PI * frequency * it / 16000) * 8000).roundToInt().toShort())
        }
        file.writeBytes(out.array())
    }

    private class Trace(private val base: AudioOutputProvider) : AudioOutputProvider by base {
        val outputs = CopyOnWriteArrayList<Output>()

        override fun getAudioOutput(config: AudioOutputProvider.OutputConfig): AudioOutput =
            Output(base.getAudioOutput(config)).also(outputs::add)
    }

    private class Output(private val base: AudioOutput) : AudioOutput by base {
        @Volatile var gain = 1f
        @Volatile var played = false
        @Volatile var bytes = 0L

        override fun play() {
            played = true
            base.play()
        }

        override fun pause() {
            played = false
            base.pause()
        }

        override fun stop() {
            played = false
            base.stop()
        }

        override fun release() {
            played = false
            base.release()
        }

        override fun setVolume(volume: Float) {
            this.gain = volume
            base.setVolume(volume)
        }

        override fun write(buffer: ByteBuffer, size: Int, presentationTimeUs: Long): Boolean {
            val before = buffer.remaining()
            val result = base.write(buffer, size, presentationTimeUs)
            bytes += before - buffer.remaining()
            return result
        }
    }

    @Test
    fun realAudioTracksOverlapAndHandoffKeepsTheAdvancedIntroAndDuplicateQueueEntries() =
        runMode(TransitionMode.CROSSFADE)

    @Test
    fun adaptiveMixAlignsEstimatedBeatsAndPausesBothActualAudioTracks() =
        runMode(TransitionMode.ADAPTIVE)

    private fun runMode(mode: TransitionMode) = runBlocking {
        val root = File(context.cacheDir, "crossfade-${UUID.randomUUID()}").apply { mkdirs() }
        val a = File(root, "a.wav")
        val b = File(root, "b.wav")
        tone(a, 220.0)
        tone(b, 660.0)
        val traces = CopyOnWriteArrayList<Trace>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val players = CopyOnWriteArrayList<ExoPlayer>()
        var current: ExoPlayer? = null
        var coordinator: CrossfadeCoordinator? = null
        var handoffs = 0
        val captured = mutableListOf<Triple<Float, Float, Pair<Long, Long>>>()
        var paused = false
        var message = ""
        try {
            val songs = listOf(a, b, a).map { LocalAudio(context).read(Uri.fromFile(it)) }
            withContext(Dispatchers.Main) {
                fun create(processor: ListeningAudioProcessor): ExoPlayer {
                    val trace = Trace(AudioTrackAudioOutputProvider.Builder(context).build())
                    traces.add(trace)
                    return PlaybackPlayerFactory.create(context, processor, false, trace)
                        .also(players::add)
                }
                current =
                    create(ListeningAudioProcessor()).apply {
                        setMediaItems(songs.map { it.mediaItem() })
                        prepare()
                        play()
                    }
                coordinator =
                    CrossfadeCoordinator(
                        scope,
                        { current!! },
                        { TransitionSettings(mode, 3) },
                        { ListeningSettings() },
                        { false },
                        { false },
                        {
                            MixTrack(
                                ListeningSettings(),
                                1.0,
                                if (mode == TransitionMode.ADAPTIVE)
                                    SongExtras(
                                        bpm = 120.0,
                                        headBeat = BeatGrid(.5, .1, .6),
                                        tailBeat = BeatGrid(.5, 0.0, .6),
                                    )
                                else SongExtras(),
                            )
                        },
                        { create(it) },
                        { incoming, _ ->
                            assertTrue(
                                "Incoming intro must already have played",
                                incoming.currentPosition in 2600..3400,
                            )
                            assertEquals(3, incoming.mediaItemCount)
                            assertEquals(
                                songs.map { it.id },
                                (0 until incoming.mediaItemCount).map {
                                    incoming.getMediaItemAt(it).mediaId
                                },
                            )
                            current = incoming
                            handoffs++
                        },
                        { message = it },
                    )
            }
            withTimeout(15_000) {
                while (withContext(Dispatchers.Main) { handoffs == 0 }) {
                    withContext(Dispatchers.Main) {
                        if (traces.size >= 2) {
                            val left = traces[0].outputs.lastOrNull()
                            val right = traces[1].outputs.lastOrNull()
                            if (
                                left != null &&
                                    right != null &&
                                    left.played &&
                                    right.played &&
                                    left.bytes > 0 &&
                                    right.bytes > 0 &&
                                    left.gain in 0.1f..0.9f &&
                                    right.gain in 0.1f..0.9f
                            ) {
                                assertEquals(1f, players[0].volume + players[1].volume, .000001f)
                                captured.add(
                                    Triple(
                                        left.gain,
                                        right.gain,
                                        left.positionUs to right.positionUs,
                                    ),
                                )
                            }
                        }
                    }
                    if (mode == TransitionMode.ADAPTIVE && !paused && captured.size >= 10) {
                        paused = true
                        withContext(Dispatchers.Main) { current!!.pause() }
                        delay(180)
                        val positions =
                            withContext(Dispatchers.Main) {
                                players[0].currentPosition to players[1].currentPosition
                            }
                        delay(250)
                        withContext(Dispatchers.Main) {
                            assertEquals(positions.first, players[0].currentPosition)
                            assertEquals(positions.second, players[1].currentPosition)
                            assertFalse(traces[0].outputs.last().played)
                            assertFalse(traces[1].outputs.last().played)
                            current!!.play()
                        }
                    }
                    delay(40)
                }
            }
            assertTrue(
                "Actual AudioTrack playback positions must advance together during the fade",
                captured.size >= 8,
            )
            assertTrue(captured.last().third.first > captured.first().third.first + 300000)
            assertTrue(captured.last().third.second > captured.first().third.second + 300000)
            assertTrue(captured.first().first > captured.last().first)
            assertTrue(captured.first().second < captured.last().second)
            if (mode == TransitionMode.ADAPTIVE) {
                assertTrue(paused)
                assertTrue(message.contains("Mezcla alineada"))
            }
            File(context.cacheDir, "qa-crossfade-ramp.csv")
                .writeText(
                    captured.joinToString("\n") {
                        "${it.first},${it.second},${it.third.first},${it.third.second}"
                    },
                )
            // Renderer volume messages use separate playback threads. Check the actual device
            // ramp monotonically; synchronous API gain conservation is asserted above.
            captured.zipWithNext().forEach { (a, b) ->
                assertTrue(b.first <= a.first + .000001f)
                assertTrue(b.second >= a.second - .000001f)
            }
            withContext(Dispatchers.Main) {
                assertEquals(1, current!!.currentMediaItemIndex)
                assertTrue(current!!.currentPosition > 2600)
                assertEquals(1f, current!!.volume, 0f)
            }
        } finally {
            withContext(Dispatchers.Main) {
                coordinator?.close()
                current?.release()
            }
            scope.cancel()
            root.deleteRecursively()
        }
    }
}
