package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class CueWavExporter(private val context: Context) {
    suspend fun export(song: Song, target: File) {
        val cue = requireNotNull(song.cueSegment())
        var complete = false
        try {
            if (song.format.equals("WAV", true)) {
                context.contentResolver.openInputStream(Uri.parse(song.uri))!!.use { input ->
                    target.outputStream().use { output ->
                        WavPcm.copySegment(input, output, cue)
                        output.fd.sync()
                    }
                }
            } else {
                // Floating-point WAV keeps decoded 24-bit values exactly and is playable by
                // Media3. Integer WAVs bypass this path and retain every original bit.
                var format: PcmFormat? = null
                var frames = 0L
                RandomAccessFile(target, "rw").use { output ->
                    output.setLength(0)
                    output.write(ByteArray(80))
                    PcmAudioReader(context)
                        .read(
                            song,
                            600,
                            { value ->
                                require(value.channels in 1..2) {
                                    "La exportación CUE de este formato admite audio mono o estéreo. WAV conserva también los canales envolventes."
                                }
                                format = value
                            },
                            { pcm ->
                                val value = requireNotNull(format)
                                require(
                                    (frames + pcm.size / value.channels) * value.channels * 4 <=
                                        0xffff_ffffL - 72,
                                ) {
                                    "La pista supera el límite WAV de 4 GB."
                                }
                                val buffer =
                                    ByteBuffer.allocate(pcm.size * 4).order(ByteOrder.LITTLE_ENDIAN)
                                pcm.forEach { buffer.putFloat(it) }
                                output.write(buffer.array())
                                frames += pcm.size / value.channels
                            },
                            preservePrecision = true,
                        )
                    val value = requireNotNull(format)
                    require(frames > 0)
                    val fmt =
                        ByteBuffer.allocate(40)
                            .order(ByteOrder.LITTLE_ENDIAN)
                            .putShort((-2).toShort())
                            .putShort(value.channels.toShort())
                            .putInt(value.rate)
                            .putInt(value.rate * value.channels * 4)
                            .putShort((value.channels * 4).toShort())
                            .putShort(32)
                            .putShort(22)
                            .putShort(32)
                            .putInt(if (value.channels == 1) 4 else 3)
                            .putInt(3)
                            .putShort(0)
                            .putShort(16)
                            .put(byteArrayOf(-128, 0, 0, -86, 0, 56, -101, 113))
                            .array()
                    val header =
                        java.io
                            .ByteArrayOutputStream()
                            .also {
                                WavPcm(
                                        fmt,
                                        value.channels,
                                        value.rate,
                                        32,
                                        true,
                                        frames * value.channels * 4,
                                    )
                                    .header(it, frames)
                            }
                            .toByteArray()
                    check(header.size == 80)
                    output.seek(0)
                    output.write(header)
                    output.fd.sync()
                }
            }
            complete = true
        } finally {
            if (!complete) target.delete()
        }
    }
}
