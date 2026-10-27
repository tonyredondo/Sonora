package com.tonyredondo.sonora

import android.content.Context
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.UUID
import kotlin.math.PI
import kotlin.math.sin
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeEncoderTest {
    @Test
    fun encoderWritesFlushAndDurationHeaderAt320kbpsAcrossSampleRates() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        for (rate in listOf(16000, 44100, 192000)) {
            val file = File(context.cacheDir, "encoded-${UUID.randomUUID()}.mp3")
            val handle = NativeAudio.encoderOpen(file.absolutePath, rate, 2)
            try {
                var position = 0
                while (position < rate * 3) {
                    val frames = minOf(4096, rate * 3 - position)
                    val samples =
                        FloatArray(frames * 2) { i ->
                            (.3 * sin(2 * PI * 440 * (position + i / 2) / rate)).toFloat()
                        }
                    NativeAudio.encoderWrite(handle, samples, frames)
                    position += frames
                }
                NativeAudio.encoderFinish(handle)
                val info =
                    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use {
                        JSONObject(NativeAudio.inspect(it.fd, 0, -1, "mp3"))
                    }
                // TagLib reports a rounded average including the Info frame. Verify the actual
                // MPEG frame bitrate index instead of treating that average as the encoder setting.
                val bytes = file.readBytes()
                var offset = 0
                var frameCount = 0
                while (offset + 4 <= bytes.size) {
                    val header = java.nio.ByteBuffer.wrap(bytes, offset, 4).int
                    assertEquals(
                        "frame at $offset",
                        0xffe00000.toInt(),
                        header and 0xffe00000.toInt(),
                    )
                    assertEquals(3, (header ushr 19) and 3) // MPEG 1
                    assertEquals(1, (header ushr 17) and 3) // Layer III
                    assertEquals(14, (header ushr 12) and 15) // 320 kb/s
                    val frameRate = intArrayOf(44100, 48000, 32000)[(header ushr 10) and 3]
                    offset += 144000 * 320 / frameRate + ((header ushr 9) and 1)
                    frameCount++
                }
                assertEquals(bytes.size, offset)
                assertTrue(frameCount > 100)
                assertEquals(44100, info.getInt("sampleRate"))
                assertEquals(2, info.getInt("channels"))
                assertTrue("duration=$info", info.getLong("durationMs") in 2950..3120)
                assertTrue(file.length() in 119000..126000)
            } finally {
                NativeAudio.encoderAbort(handle)
                file.delete()
            }
        }
    }

    @Test
    fun unsupportedMultichannelCannotCreateAnOutputFile() {
        val file =
            File(
                ApplicationProvider.getApplicationContext<Context>().cacheDir,
                "invalid-${UUID.randomUUID()}.mp3",
            )
        try {
            NativeAudio.encoderOpen(file.absolutePath, 48000, 6)
            fail("Expected explicit channel error")
        } catch (_: java.io.IOException) {}
        assertFalse(file.exists())
    }
}
