package com.tonyredondo.sonora

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EmbeddedLyricsTest {
    @Test
    fun ffmpegUsltTextFramePreservesCompleteTimedLyrics() {
        val lyric = "[00:01]Una frase completa\n[00:08]La segunda frase"
        val payload =
            byteArrayOf(1) +
                "USLT".toByteArray(Charsets.UTF_16) +
                byteArrayOf(0, 0) +
                lyric.toByteArray(Charsets.UTF_16) +
                byteArrayOf(0, 0)
        val frame =
            "TXXX".toByteArray() +
                ByteBuffer.allocate(4).putInt(payload.size).array() +
                byteArrayOf(0, 0) +
                payload
        val size = frame.size
        val tag =
            "ID3".toByteArray() +
                byteArrayOf(
                    3,
                    0,
                    0,
                    (size shr 21).toByte(),
                    ((size shr 14) and 127).toByte(),
                    ((size shr 7) and 127).toByte(),
                    (size and 127).toByte(),
                ) +
                frame
        assertEquals(lyric, EmbeddedLyrics.read(tag.inputStream()))
    }

    @Test
    fun id3LyricsRetainUnicodeLineBoundariesAndTimestamps() {
        val lyric = "[00:01]La primera canción\n[00:10]La última frase está completa"
        for ((encoding, charset) in listOf(3 to Charsets.UTF_8, 1 to Charsets.UTF_16)) {
            val payload =
                byteArrayOf(encoding.toByte()) +
                    "spa".toByteArray() +
                    (if (encoding == 1) byteArrayOf(0, 0) else byteArrayOf(0)) +
                    lyric.toByteArray(charset)
            val frame =
                "USLT".toByteArray() +
                    ByteBuffer.allocate(4)
                        .order(ByteOrder.BIG_ENDIAN)
                        .putInt(payload.size)
                        .array() +
                    byteArrayOf(0, 0) +
                    payload
            val size = frame.size
            val tag =
                "ID3".toByteArray() +
                    byteArrayOf(
                        3,
                        0,
                        0,
                        (size shr 21).toByte(),
                        ((size shr 14) and 127).toByte(),
                        ((size shr 7) and 127).toByte(),
                        (size and 127).toByte(),
                    ) +
                    frame
            assertEquals(lyric, EmbeddedLyrics.read(tag.inputStream()))
            assertEquals(
                listOf(1000L, 10000L),
                LyricsDocument.parse(EmbeddedLyrics.read(tag.inputStream())).lines.map {
                    it.timeMs
                },
            )
            assertEquals("", EmbeddedLyrics.read(tag.copyOf(tag.size - 3).inputStream()))
        }
    }

    @Test
    fun replayGainAndLyricsAreReadTogetherWithoutChangingTheSourceMp3() {
        val context =
            androidx.test.core.app.ApplicationProvider.getApplicationContext<
                android.content.Context,
            >()
        val file = java.io.File(context.cacheDir, "replaygain-${java.util.UUID.randomUUID()}.mp3")
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .context
            .assets
            .open("replaygain.mp3")
            .use { input -> file.outputStream().use(input::copyTo) }
        try {
            val hash = contentDigest(file.readBytes())
            val information = file.inputStream().use(EmbeddedLyrics::readInformation)
            assertEquals("[00:00]Una frase completa", information.lyrics)
            val gain = ReplayGain.fromMetadata(information.metadata)
            assertEquals(ReplayGain(-6.0, .9, -3.0, 1.0), gain)
            val song = LocalAudio(context).read(android.net.Uri.fromFile(file))
            assertEquals(gain, ReplayGain.fromMetadata(song.metadata))
            assertEquals(hash, contentDigest(file.readBytes()))
        } finally {
            file.delete()
        }
    }
}
