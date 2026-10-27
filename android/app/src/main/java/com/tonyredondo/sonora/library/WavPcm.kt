package com.tonyredondo.sonora

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Reads PCM RIFF without decoding: integer precision and the extensible speaker mask survive CUE
 * export.
 */
internal data class WavPcm(
    val format: ByteArray,
    val channels: Int,
    val rate: Int,
    val bits: Int,
    val floating: Boolean,
    val dataBytes: Long,
) {
    val frameBytes: Int
        get() = channels * (bits / 8)

    val frames: Long
        get() = dataBytes / frameBytes

    fun range(cue: CueSegment?): LongRange {
        val start = cue?.startFrame(rate) ?: 0L
        val end = cue?.endFrame(rate, frames) ?: frames
        require(start >= 0 && end > start && end <= frames) {
            "La pista CUE queda fuera del audio WAV."
        }
        return start until end
    }

    fun header(output: OutputStream, frameCount: Long) {
        val size = frameCount * frameBytes
        val factSize = if (floating) 12 else 0
        val total = 4L + 8 + format.size + (format.size % 2) + factSize + 8 + size + (size % 2)
        require(total <= 0xffff_ffffL) { "La pista supera el límite WAV de 4 GB." }
        output.write("RIFF".toByteArray())
        output.u32(total)
        output.write("WAVEfmt ".toByteArray())
        output.u32(format.size.toLong())
        output.write(format)
        if (format.size % 2 != 0) output.write(0)
        if (floating) {
            output.write("fact".toByteArray())
            output.u32(4)
            output.u32(frameCount)
        }
        output.write("data".toByteArray())
        output.u32(size)
    }

    fun sample(buffer: ByteBuffer): Float =
        when {
            floating && bits == 64 -> buffer.double.toFloat()
            floating -> buffer.float
            bits == 8 -> ((buffer.get().toInt() and 255) - 128) / 128f
            bits == 16 -> buffer.short / 32768f
            bits == 24 -> {
                val a = buffer.get().toInt() and 255
                val b = buffer.get().toInt() and 255
                val c = buffer.get().toInt()
                (a or (b shl 8) or (c shl 16)) / 8388608f
            }
            else -> buffer.int / 2147483648f
        }

    companion object {
        /** Leaves input at its first data byte. Unknown compressed WAVE returns null. */
        fun read(input: InputStream): WavPcm? {
            val riff = input.exact(12)
            require(
                String(riff, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                    String(riff, 8, 4, Charsets.US_ASCII) == "WAVE",
            ) {
                "El archivo no es un WAV RIFF compatible."
            }
            val remaining =
                ByteBuffer.wrap(riff).order(ByteOrder.LITTLE_ENDIAN).getInt(4).toLong() and
                    0xffff_ffffL
            require(remaining >= 4)
            var consumed = 4L
            var fmt: ByteArray? = null
            while (consumed + 8 <= remaining) {
                val header = input.exact(8)
                val name = String(header, 0, 4, Charsets.US_ASCII)
                val size =
                    ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getInt(4).toLong() and
                        0xffff_ffffL
                consumed += 8
                require(size <= remaining - consumed) { "El WAV está incompleto." }
                when (name) {
                    "fmt " -> {
                        require(fmt == null && size in 16..65536)
                        fmt = input.exact(size.toInt())
                    }
                    "data" -> {
                        val bytes =
                            requireNotNull(fmt) { "El WAV no declara su formato antes del audio." }
                        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                        val code = b.getShort(0).toInt() and 65535
                        val channels = b.getShort(2).toInt() and 65535
                        val rate = b.getInt(4)
                        val align = b.getShort(12).toInt() and 65535
                        val bits = b.getShort(14).toInt() and 65535
                        val actual =
                            if (code == 65534) {
                                require(
                                    bytes.size >= 40 && (b.getShort(16).toInt() and 65535) >= 22,
                                )
                                require(
                                    bytes
                                        .copyOfRange(26, 40)
                                        .contentEquals(
                                            byteArrayOf(
                                                0,
                                                0,
                                                0,
                                                0,
                                                16,
                                                0,
                                                -128,
                                                0,
                                                0,
                                                -86,
                                                0,
                                                56,
                                                -101,
                                                113,
                                            ),
                                        ),
                                ) {
                                    "El WAV usa un subtipo desconocido."
                                }
                                b.getShort(24).toInt() and 65535
                            } else code
                        if (actual !in setOf(1, 3)) return null
                        require(
                            rate in 8000..384000 &&
                                channels in 1..8 &&
                                bits in
                                    (if (actual == 3) setOf(32, 64) else setOf(8, 16, 24, 32)) &&
                                align == channels * (bits / 8) &&
                                size % align == 0L,
                        ) {
                            "El formato PCM WAV no es válido."
                        }
                        return WavPcm(bytes, channels, rate, bits, actual == 3, size)
                    }
                    else -> input.skipExactly(size)
                }
                if (size % 2 != 0L) input.skipExactly(1)
                consumed += size + (size % 2)
            }
            error("El WAV no contiene audio.")
        }

        suspend fun copySegment(input: InputStream, output: OutputStream, cue: CueSegment) {
            val wav =
                read(input)
                    ?: error(
                        "Este WAV comprimido necesita convertirse antes de exportar la pista CUE.",
                    )
            val range = wav.range(cue)
            val frames = range.last - range.first + 1
            wav.header(output, frames)
            input.skipExactly(range.first * wav.frameBytes)
            var left = frames * wav.frameBytes
            val block = ByteArray(64 * 1024)
            while (left > 0) {
                coroutineContext.ensureActive()
                val n = input.read(block, 0, minOf(left, block.size.toLong()).toInt())
                check(n > 0) { "El WAV terminó antes de completar la pista." }
                output.write(block, 0, n)
                left -= n
            }
            if (frames * wav.frameBytes % 2 != 0L) output.write(0)
        }
    }
}

internal fun InputStream.exact(count: Int): ByteArray =
    ByteArray(count).also { buffer ->
        var position = 0
        while (position < count) {
            val n = read(buffer, position, count - position)
            require(n > 0) { "El archivo de audio está incompleto." }
            position += n
        }
    }

internal fun InputStream.skipExactly(bytes: Long) {
    var left = bytes
    while (left > 0) {
        val n = skip(left)
        if (n > 0) left -= n
        else {
            require(read() != -1) { "El archivo de audio está incompleto." }
            left--
        }
    }
}

internal fun OutputStream.u32(value: Long) {
    write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value.toInt()).array())
}
