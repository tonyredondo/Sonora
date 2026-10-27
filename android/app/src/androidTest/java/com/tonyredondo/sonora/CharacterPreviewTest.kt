package com.tonyredondo.sonora

import androidx.test.core.app.ApplicationProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class CharacterPreviewTest {
    @Test
    fun sampleIsRealMono16kPcmAndSelectsThreeSeparatedSections() {
        val sampler = CharacterSampler(120.0)
        val rate = 48000
        repeat(rate * 120) { frame ->
            val t = frame.toDouble() / rate
            sampler.add(t, rate, if (t < 35) .2 else if (t < 85) .4 else .6)
        }
        val wave = sampler.finish()
        val header = ByteBuffer.wrap(wave).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("RIFF", String(wave.copyOfRange(0, 4)))
        assertEquals(1, header.getShort(22).toInt())
        assertEquals(16000, header.getInt(24))
        assertEquals(16, header.getShort(34).toInt())
        assertEquals(90.0, (wave.size - 44) / 32000.0, .02)
        fun average(seconds: Int): Double =
            (0 until 16000).sumOf {
                header.getShort(44 + (seconds * 16000 + it) * 2).toDouble() / 32768
            } / 16000
        assertEquals(.2, average(10), .01)
        assertEquals(.4, average(40), .01)
        assertEquals(.6, average(75), .01)
    }

    @Test
    fun decoderProducesPreviewWithoutChangingTheSource() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val source = java.io.File(app.cacheDir, "preview-${java.util.UUID.randomUUID()}.wav")
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .context
            .assets
            .open("fixture.wav")
            .use { input -> source.outputStream().use(input::copyTo) }
        val before = contentDigest(source.readBytes())
        try {
            val result =
                LocalAudioAnalyzer(app)
                    .analyze(
                        Song("preview", android.net.Uri.fromFile(source).toString(), "Preview QA"),
                    )
            assertNotNull(result.characterWav)
            assertTrue(result.characterWav!!.size > 32000)
            assertEquals(before, contentDigest(source.readBytes()))
        } finally {
            source.delete()
        }
    }
}
