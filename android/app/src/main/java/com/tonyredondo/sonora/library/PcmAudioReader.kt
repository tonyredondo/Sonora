package com.tonyredondo.sonora

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.Uri
import androidx.media3.inspector.MediaExtractorCompat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

internal data class PcmFormat(val rate: Int, val channels: Int, val durationSeconds: Double)

/** One range contract for analysis and encoding. Callbacks own each bounded, interleaved block. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class PcmAudioReader(private val context: Context) {
    suspend fun read(
        song: Song,
        budgetSeconds: Long,
        onFormat: (PcmFormat) -> Unit,
        onBlock: (FloatArray) -> Unit,
        preservePrecision: Boolean = false,
    ) {
        val cue = song.cueSegment()
        val deadline = System.nanoTime() + budgetSeconds * 1_000_000_000L
        suspend fun checkpoint() {
            coroutineContext.ensureActive()
            check(System.nanoTime() < deadline) { "El procesamiento de audio tardó demasiado." }
        }
        if (song.format.equals("WAV", true)) {
            val supported =
                context.contentResolver.openInputStream(Uri.parse(song.uri))!!.use { input ->
                    val wav = WavPcm.read(input) ?: return@use false
                    val range = wav.range(cue)
                    require((range.last - range.first + 1).toDouble() / wav.rate <= 7200) {
                        "Se admiten pistas de hasta dos horas."
                    }
                    onFormat(
                        PcmFormat(
                            wav.rate,
                            wav.channels,
                            (range.last - range.first + 1).toDouble() / wav.rate,
                        ),
                    )
                    input.skipExactly(range.first * wav.frameBytes)
                    var remaining = range.last - range.first + 1
                    while (remaining > 0) {
                        checkpoint()
                        val frames = minOf(remaining, 4096).toInt()
                        val buffer =
                            ByteBuffer.wrap(input.exact(frames * wav.frameBytes))
                                .order(ByteOrder.LITTLE_ENDIAN)
                        onBlock(FloatArray(frames * wav.channels) { wav.sample(buffer) })
                        remaining -= frames
                    }
                    true
                }
            if (supported) return
        }
        // Platform FLAC extraction may already quantize to PCM16. Use the same compressed
        // extractors as playback and ask the codec for float output to preserve PCM24.
        val extractor = MediaExtractorCompat(context)
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, Uri.parse(song.uri), null)
            val track =
                (0 until extractor.trackCount).firstOrNull {
                    extractor
                        .getTrackFormat(it)
                        .getString(MediaFormat.KEY_MIME)
                        ?.startsWith("audio/") == true
                } ?: error("No se encontró una pista de audio.")
            val format = extractor.getTrackFormat(track)
            val sourceEncoding =
                if (format.containsKey("exo-pcm-encoding-int"))
                    format.getInteger("exo-pcm-encoding-int")
                else null
            if (preservePrecision)
                require(sourceEncoding != androidx.media3.common.C.ENCODING_PCM_32BIT) {
                    "Este archivo de 32 bits necesita un decodificador sin reducción de precisión para exportar una pista CUE. Los archivos WAV se conservan directamente."
                }
            val sourceEnd =
                if (format.containsKey(MediaFormat.KEY_DURATION))
                    format.getLong(MediaFormat.KEY_DURATION)
                else if (cue == null) song.durationMs * 1000 else 0
            val start = cue?.startUs ?: 0L
            val end = cue?.endUs ?: sourceEnd
            require(
                end > start &&
                    end - start <= 7_200_000_000L &&
                    (sourceEnd <= 0 || end <= sourceEnd + 1000),
            ) {
                "La duración o el intervalo de audio no es válido."
            }
            extractor.selectTrack(track)
            // MP3's approximate seek map can land just after the requested point. Decode
            // a bounded preroll for its bit reservoir, then trim decoded sample timestamps.
            if (start > 0)
                extractor.seekTo(
                    (start - 1_000_000).coerceAtLeast(0),
                    MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC,
                )
            val decoder =
                MediaCodec.createDecoderByType(
                    requireNotNull(format.getString(MediaFormat.KEY_MIME)),
                )
            codec = decoder
            // Float decoding retains 24-bit lossless input. WAV integer32 uses the raw reader
            // above.
            if (format.getString(MediaFormat.KEY_MIME) != "audio/raw")
                format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
            if (start > 0) {
                // Gapless priming belongs to the source beginning, not a mid-file seek.
                format.setInteger(MediaFormat.KEY_ENCODER_DELAY, 0)
                format.setInteger(MediaFormat.KEY_ENCODER_PADDING, 0)
            }
            decoder.configure(format, null, null, 0)
            decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var published: PcmFormat? = null
            var inputEnded = false
            var outputEnded = false
            var frames = 0L
            val info = MediaCodec.BufferInfo()
            while (!outputEnded) {
                checkpoint()
                if (!inputEnded) {
                    val index = decoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = requireNotNull(decoder.getInputBuffer(index))
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(
                                index,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEnded = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                when (val index = decoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val out = decoder.outputFormat
                        rate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        encoding =
                            if (out.containsKey(MediaFormat.KEY_PCM_ENCODING))
                                out.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            else AudioFormat.ENCODING_PCM_16BIT
                        if (
                            preservePrecision &&
                                sourceEncoding == androidx.media3.common.C.ENCODING_PCM_24BIT
                        )
                            require(encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                                "El decodificador de este dispositivo reduce la precisión de 24 bits. No se ha exportado el archivo."
                            }
                        require(
                            rate in 8000..384000 &&
                                channels in 1..8 &&
                                encoding in
                                    setOf(
                                        AudioFormat.ENCODING_PCM_16BIT,
                                        AudioFormat.ENCODING_PCM_FLOAT,
                                    ),
                        ) {
                            "El decodificador no admite este formato PCM."
                        }
                        val value = PcmFormat(rate, channels, (end - start) / 1_000_000.0)
                        require(published == null || published == value) {
                            "El formato cambió durante la pista."
                        }
                        if (published == null) {
                            onFormat(value)
                            published = value
                        }
                    }
                    else ->
                        if (index >= 0)
                            try {
                                if (
                                    info.size > 0 &&
                                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                                ) {
                                    val value =
                                        PcmFormat(rate, channels, (end - start) / 1_000_000.0)
                                    if (published == null) {
                                        onFormat(value)
                                        published = value
                                    }
                                    val sampleBytes =
                                        if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                                    val frameBytes = sampleBytes * channels
                                    require(info.size % frameBytes == 0) {
                                        "El decodificador devolvió una muestra incompleta."
                                    }
                                    val buffer =
                                        requireNotNull(decoder.getOutputBuffer(index))
                                            .order(ByteOrder.nativeOrder())
                                    val bufferStart =
                                        kotlin.math
                                            .round(
                                                info.presentationTimeUs.toDouble() * rate /
                                                    1_000_000,
                                            )
                                            .toLong()
                                    val first = cue?.startFrame(rate) ?: 0L
                                    val last =
                                        cue?.endFrame(
                                            rate,
                                            ((end.toDouble() * rate / 1_000_000) + .5).toLong(),
                                        ) ?: ((end.toDouble() * rate / 1_000_000) + .5).toLong()
                                    val skip =
                                        (first - bufferStart)
                                            .coerceIn(0, (info.size / frameBytes).toLong())
                                            .toInt()
                                    val count =
                                        minOf(
                                            info.size / frameBytes - skip,
                                            (last - bufferStart - skip)
                                                .coerceAtLeast(0)
                                                .coerceAtMost(Int.MAX_VALUE.toLong())
                                                .toInt(),
                                        )
                                    buffer.position(info.offset + skip * frameBytes)
                                    buffer.limit(buffer.position() + count * frameBytes)
                                    while (buffer.hasRemaining()) {
                                        val countFrames =
                                            minOf(4096, buffer.remaining() / frameBytes)
                                        val pcm =
                                            FloatArray(countFrames * channels) {
                                                if (encoding == AudioFormat.ENCODING_PCM_FLOAT)
                                                    buffer.float
                                                else buffer.short / 32768f
                                            }
                                        require(pcm.all { it.isFinite() }) {
                                            "El audio contiene muestras inválidas."
                                        }
                                        onBlock(pcm)
                                        frames += countFrames
                                    }
                                    outputEnded = bufferStart + info.size / frameBytes >= last
                                }
                                outputEnded =
                                    outputEnded ||
                                        info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            } finally {
                                decoder.releaseOutputBuffer(index, false)
                            }
                }
            }
            require(frames > 0) { "La pista no contiene audio en ese intervalo." }
            if (cue?.endCDFrame != null)
                require(
                    kotlin.math.abs(frames - (cue.endFrame(rate, 0) - cue.startFrame(rate))) <= 1,
                ) {
                    "La pista terminó antes de completar el intervalo CUE."
                }
        } finally {
            try {
                codec?.let {
                    try {
                        it.stop()
                    } finally {
                        it.release()
                    }
                }
            } finally {
                extractor.release()
            }
        }
    }
}
