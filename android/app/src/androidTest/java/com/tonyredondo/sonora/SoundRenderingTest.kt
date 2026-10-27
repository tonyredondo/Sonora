package com.tonyredondo.sonora

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class SoundRenderingTest {
    @Test fun timeStretchChangesDurationWhilePreservingThePitch() = verify(.8f, 1f, 2.5, 440.0)

    @Test fun pitchShiftChangesFrequencyWhilePreservingDuration() = verify(1f, 1.5f, 2.0, 660.0)

    private fun verify(speed: Float, pitch: Float, duration: Double, frequency: Double) {
        val processor = SonicAudioProcessor()
        processor.setSpeed(speed)
        processor.setPitch(pitch)
        processor.configure(AudioProcessor.AudioFormat(16000, 1, C.ENCODING_PCM_16BIT))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val source = ByteBuffer.allocateDirect(64000).order(ByteOrder.nativeOrder())
        repeat(32000) {
            source.putShort((sin(2 * PI * 440 * it / 16000) * 12000).toInt().toShort())
        }
        source.flip()
        val output = ByteArrayOutputStream()
        fun collect() {
            val data = processor.output
            val bytes = ByteArray(data.remaining())
            data.get(bytes)
            output.write(bytes)
        }
        processor.queueInput(source)
        collect()
        processor.queueEndOfStream()
        collect()
        val audio =
            ByteBuffer.wrap(output.toByteArray()).order(ByteOrder.nativeOrder()).asShortBuffer()
        assertEquals(duration, audio.limit() / 16000.0, .04)
        val start = 1600
        val end = audio.limit() - 1600
        val crossings = (start + 1 until end).count { audio[it - 1] < 0 && audio[it] >= 0 }
        assertEquals(frequency, crossings * 16000.0 / (end - start), 12.0)
        processor.reset()
    }
}
