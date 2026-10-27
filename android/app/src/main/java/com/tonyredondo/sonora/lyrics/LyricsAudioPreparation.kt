package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.*

internal data class LyricsAudio(val file: File, val sha256: String, val duration: Double) :
    AutoCloseable {
    override fun close() {
        check(!file.exists() || file.delete()) {
            "No se pudo retirar el audio temporal del análisis."
        }
    }
}

/** Complete source audio, not the 90-second character preview. Only derived PCM is staged. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class LyricsAudioPreparation(private val context: Context) {
    suspend fun prepare(song: Song): LyricsAudio {
        require(song.durationMs in 1000..600000) {
            "El análisis de letras admite canciones de entre un segundo y diez minutos."
        }
        val before = LocalAudio(context).read(Uri.parse(song.uri))
        require(
            (song.modified == 0L || song.modified == before.modified) &&
                (song.size == 0L || song.size == before.size),
        ) {
            "El archivo ha cambiado. Vuelve a abrir la canción antes de analizarla."
        }
        val file = File.createTempFile("lyrics-analysis-", ".wav", context.cacheDir)
        val processor = SonicAudioProcessor()
        var complete = false
        try {
            var channels = 0
            var rate = 0
            var bytes = 0L
            RandomAccessFile(file, "rw").use { output ->
                output.write(ByteArray(44))
                fun drain(buffer: ByteBuffer) {
                    require(bytes + buffer.remaining() <= 19_200_000) {
                        "El audio supera los diez minutos."
                    }
                    val transfer = ByteArray(minOf(buffer.remaining(), 8192))
                    while (buffer.hasRemaining()) {
                        val n = minOf(buffer.remaining(), transfer.size)
                        buffer.get(transfer, 0, n)
                        output.write(transfer, 0, n)
                        bytes += n
                    }
                }
                PcmAudioReader(context)
                    .read(
                        song,
                        120,
                        { format ->
                            require(format.durationSeconds in 1.0..600.0)
                            channels = format.channels
                            rate = format.rate
                            if (rate != 16000) {
                                processor.setOutputSampleRateHz(16000)
                                processor.configure(
                                    AudioProcessor.AudioFormat(rate, 1, C.ENCODING_PCM_16BIT),
                                )
                                processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
                            }
                        },
                        { pcm ->
                            val mono =
                                ByteBuffer.allocateDirect(pcm.size / channels * 2)
                                    .order(ByteOrder.nativeOrder())
                            for (frame in pcm.indices step channels) {
                                var sample = 0.0
                                repeat(channels) { sample += pcm[frame + it] }
                                mono.putShort(
                                    (sample / channels * 32768)
                                        .roundToInt()
                                        .coerceIn(-32768, 32767)
                                        .toShort(),
                                )
                            }
                            mono.flip()
                            if (rate == 16000) drain(mono)
                            else {
                                processor.queueInput(mono)
                                drain(processor.output)
                            }
                        },
                    )
                if (rate != 16000) {
                    processor.queueEndOfStream()
                    drain(processor.output)
                }
                require(bytes in 32000..19_200_000 && bytes % 2 == 0L)
                val fmt =
                    ByteBuffer.allocate(16)
                        .order(ByteOrder.LITTLE_ENDIAN)
                        .putShort(1)
                        .putShort(1)
                        .putInt(16000)
                        .putInt(32000)
                        .putShort(2)
                        .putShort(16)
                        .array()
                val header =
                    java.io
                        .ByteArrayOutputStream()
                        .also { WavPcm(fmt, 1, 16000, 16, false, bytes).header(it, bytes / 2) }
                        .toByteArray()
                check(header.size == 44)
                output.seek(0)
                output.write(header)
                output.fd.sync()
            }
            val after = LocalAudio(context).read(Uri.parse(song.uri))
            require(before.modified == after.modified && before.size == after.size) {
                "El archivo cambió mientras se preparaba el análisis."
            }
            val duration = (file.length() - 44) / 32000.0
            require(abs(duration - song.durationMs / 1000.0) <= .1) {
                "La duración del audio no coincide con esta canción."
            }
            val hash = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val block = ByteArray(65536)
                while (true) {
                    val n = input.read(block)
                    if (n < 0) break
                    hash.update(block, 0, n)
                }
            }
            complete = true
            return LyricsAudio(file, hash.digest().joinToString("") { "%02x".format(it) }, duration)
        } finally {
            processor.reset()
            if (!complete) file.delete()
        }
    }
}
