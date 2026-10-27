package com.tonyredondo.sonora

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningAudioProcessor : BaseAudioProcessor() {
    private data class Controls(val settings: ListeningSettings, val multiplier: Double)

    @Volatile private var controls = Controls(ListeningSettings(), 1.0)
    private var applied: Controls? = null
    private var kernel: ListeningKernel? = null

    fun apply(settings: ListeningSettings, multiplier: Double) {
        settings.validate()
        require(multiplier.isFinite() && multiplier in 0.0..100.0)
        controls =
            Controls(
                settings.copy(
                    equalizer = settings.equalizer.copy(gains = settings.equalizer.gains.toList()),
                ),
                multiplier,
            )
    }

    override fun onConfigure(
        inputAudioFormat: AudioProcessor.AudioFormat,
    ): AudioProcessor.AudioFormat {
        if (
            inputAudioFormat.encoding !in listOf(C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT) ||
                inputAudioFormat.channelCount !in 1..8 ||
                inputAudioFormat.sampleRate !in 8000..384000
        )
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        return inputAudioFormat
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        kernel =
            if (inputAudioFormat.sampleRate > 0)
                ListeningKernel(inputAudioFormat.sampleRate, inputAudioFormat.channelCount)
            else null
        applied = null
    }

    override fun onReset() {
        kernel = null
        applied = null
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val format = inputAudioFormat
        val engine = checkNotNull(kernel)
        val value = controls
        if (value != applied) {
            engine.update(value.settings, value.multiplier)
            applied = value
        }
        val width = if (format.encoding == C.ENCODING_PCM_FLOAT) 4 else 2
        val bytes = inputBuffer.remaining()
        require(bytes % (format.channelCount * width) == 0)
        val output = replaceOutputBuffer(bytes).order(ByteOrder.nativeOrder())
        inputBuffer.order(ByteOrder.nativeOrder())
        while (inputBuffer.hasRemaining()) {
            engine.beginFrame()
            repeat(format.channelCount) { channel ->
                val sample =
                    if (width == 4) inputBuffer.float.toDouble() else inputBuffer.short / 32768.0
                val processed = engine.sample(sample, channel)
                if (width == 4) output.putFloat(processed.toFloat())
                else
                    output.putShort(
                        (processed * 32768).roundToInt().coerceIn(-32768, 32767).toShort(),
                    )
            }
        }
        output.flip()
    }
}
