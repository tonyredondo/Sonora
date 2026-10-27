package com.tonyredondo.sonora

import androidx.media3.extractor.metadata.id3.BinaryFrame
import androidx.media3.extractor.metadata.id3.Id3Decoder
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import java.io.InputStream
import java.nio.charset.Charset
import java.util.Locale

/** Reads bounded ID3 lyrics without decoding or modifying any audio payload. */
data class EmbeddedAudioInformation(val lyrics: String = "", val metadata: String = "{}")

object EmbeddedLyrics {
    fun read(input: InputStream): String = readInformation(input).lyrics

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    fun readInformation(input: InputStream): EmbeddedAudioInformation {
        val header = input.readExactly(10) ?: return EmbeddedAudioInformation()
        if (
            !header.copyOfRange(0, 3).contentEquals("ID3".toByteArray()) ||
                header[3].toInt() !in 2..4
        )
            return EmbeddedAudioInformation()
        if ((6..9).any { header[it].toInt() and 128 != 0 }) return EmbeddedAudioInformation()
        val size =
            (6..9).fold(0) { value, index -> (value shl 7) or (header[index].toInt() and 127) }
        if (size !in 1..16_000_000) return EmbeddedAudioInformation()
        val body = input.readExactly(size) ?: return EmbeddedAudioInformation()
        val bytes = header + body
        val metadata =
            try {
                Id3Decoder(Id3Decoder.NO_ARTWORK_PREDICATE).decode(bytes, bytes.size)
            } catch (_: RuntimeException) {
                null
            } ?: return EmbeddedAudioInformation()
        var plain = ""
        var timed: String? = null
        val tags = org.json.JSONObject()
        for (i in 0 until metadata.length()) {
            val entry = metadata[i]
            if (entry is TextInformationFrame && entry.id == "TXXX") {
                val key = entry.description?.lowercase(Locale.ROOT)
                if (
                    key in
                        setOf(
                            "replaygain_track_gain",
                            "replaygain_track_peak",
                            "replaygain_album_gain",
                            "replaygain_album_peak",
                        )
                ) {
                    val raw = entry.values.firstOrNull()?.trim()?.replace(Regex("(?i)\\s*db$"), "")
                    raw?.toDoubleOrNull()?.takeIf { it.isFinite() }?.let { tags.put(key!!, it) }
                }
            }
            val value =
                when {
                        entry is BinaryFrame && entry.id in setOf("USLT", "ULT") ->
                            unsynchronized(entry.data)
                        entry is TextInformationFrame &&
                            entry.id == "TXXX" &&
                            entry.description?.uppercase(Locale.ROOT) in
                                setOf(
                                    "LYRICS",
                                    "UNSYNCEDLYRICS",
                                    "SYNCEDLYRICS",
                                    "LRC",
                                    "USLT",
                                    "ULT",
                                ) -> entry.values.joinToString("\n")
                        else -> ""
                    }
                    .takeIf { it.length <= 1_000_000 }
                    .orEmpty()
            if (value.isNotBlank()) {
                if (timed == null && LyricsDocument.parse(value).isTimed) timed = value
                if (plain.isBlank()) plain = value
            }
        }
        return EmbeddedAudioInformation(timed ?: plain, tags.toString())
    }

    private fun unsynchronized(bytes: ByteArray): String {
        if (bytes.size < 5) return ""
        val encoding = bytes[0].toInt()
        val charset =
            when (encoding) {
                0 -> Charsets.ISO_8859_1
                1 -> Charsets.UTF_16
                2 -> Charset.forName("UTF-16BE")
                3 -> Charsets.UTF_8
                else -> return ""
            }
        val width = if (encoding in 1..2) 2 else 1
        var position = 4
        while (position + width <= bytes.size) {
            if (
                bytes[position] == 0.toByte() && (width == 1 || bytes[position + 1] == 0.toByte())
            ) {
                position += width
                return String(bytes, position, bytes.size - position, charset)
                    .trimEnd('\u0000')
                    .removePrefix("\uFEFF")
            }
            position += width
        }
        return ""
    }

    private fun InputStream.readExactly(size: Int): ByteArray? {
        val bytes = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(bytes, offset, size - offset)
            if (count < 0) return null
            if (count == 0) {
                val byte = read()
                if (byte < 0) return null
                bytes[offset++] = byte.toByte()
            } else offset += count
        }
        return bytes
    }
}
