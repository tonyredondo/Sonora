package com.tonyredondo.sonora

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningProcessorTest {
    @Test
    fun pcm16BypassIsBitExactAndLiveBalanceKeepsTheFrameCount() {
        val processor = ListeningAudioProcessor()
        processor.configure(AudioProcessor.AudioFormat(48000, 2, C.ENCODING_PCM_16BIT))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        fun input() =
            ByteBuffer.allocateDirect(19200).order(ByteOrder.nativeOrder()).apply {
                repeat(4800) {
                    putShort(if (it % 2 == 0) 8000 else -16000)
                    putShort(if (it % 2 == 0) -4000 else 12000)
                }
                flip()
            }
        val source = input()
        val expected = ByteArray(source.remaining())
        source.duplicate().get(expected)
        processor.queueInput(source)
        val rendered = processor.output
        val actual = ByteArray(rendered.remaining())
        rendered.get(actual)
        assertArrayEquals(expected, actual)
        processor.apply(ListeningSettings(balance = 1f), 1.0)
        processor.queueInput(input())
        val output = processor.output.order(ByteOrder.nativeOrder()).asShortBuffer()
        assertEquals(9600, output.remaining())
        for (frame in 500 until 4800) {
            assertEquals(0, output[frame * 2].toInt())
            assertTrue(output[frame * 2 + 1].toInt() != 0)
        }
        processor.reset()
    }

    @Test
    fun floatPcmEqualizerAndReplayGainMeasureTheExpectedOutput() {
        val processor = ListeningAudioProcessor()
        processor.apply(
            ListeningSettings(
                equalizer = EqualizerSettings(true, List(10) { if (it == 5) 6f else 0f }, -3f),
            ),
            .5,
        )
        processor.configure(AudioProcessor.AudioFormat(48000, 1, C.ENCODING_PCM_FLOAT))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val source =
            ByteBuffer.allocateDirect(48000 * 4).order(ByteOrder.nativeOrder()).apply {
                repeat(48000) { putFloat((sin(2 * PI * 1000 * it / 48000) * .05).toFloat()) }
                flip()
            }
        processor.queueInput(source)
        val output = processor.output.order(ByteOrder.nativeOrder()).asFloatBuffer()
        assertEquals(48000, output.remaining())
        val rms = sqrt((4800 until 48000).sumOf { output[it].toDouble().pow(2) } / 43200)
        assertEquals(3.0 + 20 * log10(.5), 20 * log10(rms / (.05 / sqrt(2.0))), .12)
        processor.reset()
    }
}
