package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.sin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AudioAnalysisTest {
    @Test
    fun actualDecoderFindsTempoAndKeepsQuietPassagesQuiet() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val rate = 16000
        val frames = rate * 20
        val bytes = ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN)
        bytes
            .put("RIFF".toByteArray())
            .putInt(36 + frames * 2)
            .put("WAVEfmt ".toByteArray())
            .putInt(16)
        bytes
            .putShort(1)
            .putShort(1)
            .putInt(rate)
            .putInt(rate * 2)
            .putShort(2)
            .putShort(16)
            .put("data".toByteArray())
            .putInt(frames * 2)
        repeat(frames) { i ->
            val t = i.toDouble() / rate
            val attack = if (t % .5 < .05) 1.0 else .04
            val amplitude = if (t < 10) .08 else .8
            bytes.putShort(
                (sin(t * 2 * Math.PI * 440) * attack * amplitude * 32767).toInt().toShort(),
            )
        }
        val file = File(context.cacheDir, "audio-qa-${UUID.randomUUID()}.wav")
        try {
            file.writeBytes(bytes.array())
            val before = contentDigest(file.readBytes())
            val song = LocalAudio(context).read(Uri.fromFile(file))
            val result = LocalAudioAnalyzer(context).analyze(song)
            assertEquals(120.0, requireNotNull(result.bpm), 2.0)
            assertEquals(512, result.waveform.size)
            assertTrue(result.volumeSupported)
            assertNotNull(result.volume)
            assertNotNull(result.headBeat)
            assertNotNull(result.tailBeat)
            assertTrue(result.volume!!.peak > .7)
            assertTrue(result.waveform.take(240).max() < result.waveform.drop(280).max() / 3)
            assertEquals(before, contentDigest(file.readBytes()))
        } finally {
            file.delete()
        }
    }

    @Test
    fun queuePreparationRestoresItsPersistentResultWithoutReadingAudioAgain() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val graph = app.graph
        val file = File(app.cacheDir, "cache-qa-${UUID.randomUUID()}.wav")
        var songId: String? = null
        try {
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("fixture.wav")
                .use { source -> file.outputStream().use(source::copyTo) }
            val song = LocalAudio(app).read(Uri.fromFile(file))
            songId = song.id
            graph.store.saveSongs(listOf(song), inLibrary = false)
            fun enqueue() =
                androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
                    .runOnMainSync { graph.preparation.prepare(listOf(song.id)) }
            suspend fun result(): SongExtras =
                kotlinx.coroutines.withTimeout(10000) {
                    while (
                        graph.extras.value[song.id]?.progress?.get(PreparationStage.AUDIO)?.state !=
                            PreparationState.READY
                    ) kotlinx.coroutines.delay(20)
                    requireNotNull(graph.extras.value[song.id])
                }
            enqueue()
            val first = result()
            assertTrue(first.waveform.isNotEmpty())
            file.delete()
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().runOnMainSync {
                graph.extras.value = graph.extras.value - song.id
            }
            enqueue()
            val restored = result()
            assertEquals(first.waveform, restored.waveform)
            assertEquals(first.bpm, restored.bpm)
            assertTrue(first.volumeSupported)
            assertNotNull(first.volume)
            assertEquals(first.volume, restored.volume)
        } finally {
            songId?.let { graph.store.removeSongs(listOf(it)) }
            file.delete()
        }
    }
}
