package com.tonyredondo.sonora

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * At most three separated 30-second sections, resampled by Media3 rather than dropping PCM frames.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class CharacterSampler(duration: Double) {
    private val sections =
        if (duration <= 90) listOf(0.0 to duration)
        else
            listOf((duration - 90) * .1, (duration - 30) / 2, duration - 30 - (duration - 90) * .1)
                .map { it to it + 30 }
    private val output = ByteArrayOutputStream()
    private val input = ByteBuffer.allocateDirect(8192).order(ByteOrder.nativeOrder())
    private val processor = SonicAudioProcessor()
    private val transfer = ByteArray(8192)
    private var section = -1
    private var sampleRate = 0

    fun add(time: Double, rate: Int, value: Double) {
        val next = sections.indexOfFirst { time >= it.first && time < it.second }
        if (next < 0) {
            if (sampleRate != 0) endSection()
            section = -1
            return
        }
        if (next != section || sampleRate != rate) {
            endSection()
            section = next
            sampleRate = rate
            processor.setOutputSampleRateHz(16000)
            processor.configure(AudioProcessor.AudioFormat(rate, 1, C.ENCODING_PCM_16BIT))
            processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        }
        input.putShort(
            ((if (value.isFinite()) value else 0.0) * 32768)
                .roundToInt()
                .coerceIn(-32768, 32767)
                .toShort(),
        )
        if (!input.hasRemaining()) feed()
    }

    private fun feed() {
        input.flip()
        if (sampleRate == 16000) copy(input)
        else {
            processor.queueInput(input)
            copy(processor.output)
        }
        input.clear()
    }

    private fun copy(buffer: ByteBuffer) {
        while (buffer.hasRemaining()) {
            val count = minOf(transfer.size, buffer.remaining())
            buffer.get(transfer, 0, count)
            val keep = minOf(count, 90 * 32000 - output.size())
            if (keep > 0) output.write(transfer, 0, keep)
        }
    }

    private fun endSection() {
        if (sampleRate == 0) return
        feed()
        if (sampleRate != 16000) {
            processor.queueEndOfStream()
            copy(processor.output)
        }
        processor.reset()
        sampleRate = 0
    }

    fun finish(): ByteArray {
        endSection()
        val pcm = output.toByteArray()
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(pcm.size + 36).put("WAVEfmt ".toByteArray())
        header
            .putInt(16)
            .putShort(1)
            .putShort(1)
            .putInt(16000)
            .putInt(32000)
            .putShort(2)
            .putShort(16)
        header.put("data".toByteArray()).putInt(pcm.size)
        return header.array() + pcm
    }
}
