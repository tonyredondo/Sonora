package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.sin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class LyricsAudioTest {
    @Test
    fun wholeSongAndCueAudioAreCanonicalAndNeverTruncatedToTheCharacterPreview() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val source = File(context.cacheDir, "lyrics-audio-qa-${UUID.randomUUID()}.wav")
        try {
            val frames = 8000 * 91
            val bytes = ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN)
            bytes
                .put("RIFF".toByteArray())
                .putInt(frames * 2 + 36)
                .put("WAVEfmt ".toByteArray())
                .putInt(16)
                .putShort(1)
                .putShort(1)
                .putInt(8000)
                .putInt(16000)
                .putShort(2)
                .putShort(16)
                .put("data".toByteArray())
                .putInt(frames * 2)
            repeat(frames) {
                bytes.putShort((sin(it * 2 * Math.PI * 220 / 8000) * 12000).toInt().toShort())
            }
            source.writeBytes(bytes.array())
            val digest = contentDigest(source.readBytes())
            val song = LocalAudio(context).read(Uri.fromFile(source))
            val first = LyricsAudioPreparation(context).prepare(song)
            val path = first.file
            first.use {
                assertEquals(91.0, it.duration, .001)
                assertEquals(91 * 32000L + 44, it.file.length())
                assertEquals(contentDigest(it.file.readBytes()), it.sha256)
                it.file.inputStream().use { input ->
                    val wav = WavPcm.read(input)!!
                    assertEquals(1, wav.channels)
                    assertEquals(16000, wav.rate)
                    assertEquals(16, wav.bits)
                }
            }
            assertFalse(path.exists())
            val cue = CueSegment("file:///analysis.cue", 1, 45 * 75, 55 * 75).applyTo(song)
            LyricsAudioPreparation(context).prepare(cue).use {
                assertEquals(10.0, it.duration, .001)
                assertEquals(320044L, it.file.length())
            }
            assertEquals(digest, contentDigest(source.readBytes()))
        } finally {
            source.delete()
        }
    }
}
