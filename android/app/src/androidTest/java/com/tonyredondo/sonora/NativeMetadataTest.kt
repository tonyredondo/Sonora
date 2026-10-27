package com.tonyredondo.sonora

import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeMetadataTest {
    @Test
    fun borrowedDescriptorReadsOnlyItsRangeWithoutMovingTheSharedCursor() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val file = File(context.cacheDir, "descriptor-${UUID.randomUUID()}.bin")
        val audio =
            InstrumentationRegistry.getInstrumentation().context.assets.open("replaygain.mp3").use {
                it.readBytes()
            }
        try {
            file.writeBytes(ByteArray(137) { 42 } + audio + ByteArray(73) { 99 })
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                android.system.Os.lseek(
                    descriptor.fileDescriptor,
                    57,
                    android.system.OsConstants.SEEK_SET,
                )
                val info =
                    JSONObject(NativeAudio.inspect(descriptor.fd, 137, audio.size.toLong(), "mp3"))
                assertEquals(
                    "ReplayGain QA",
                    info.getJSONObject("fields").getJSONArray("TITLE").getString(0),
                )
                assertEquals(
                    57L,
                    android.system.Os.lseek(
                        descriptor.fileDescriptor,
                        0,
                        android.system.OsConstants.SEEK_CUR,
                    ),
                )
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun nativeTagsPreserveAudioAndMultilingualUnicodeFieldsAndArtwork() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val id = UUID.randomUUID().toString()
        val source = File(context.cacheDir, "native-source-$id.mp3")
        val copy = File(context.cacheDir, "native-copy-$id.mp3")
        InstrumentationRegistry.getInstrumentation().context.assets.open("replaygain.mp3").use {
            input ->
            source.outputStream().use(input::copyTo)
        }
        val original = source.readBytes()
        source.copyTo(copy)
        fun read(file: File) =
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use {
                JSONObject(NativeAudio.inspect(it.fd, 0, -1, "mp3"))
            }
        try {
            assertEquals(
                "ReplayGain QA",
                read(source).getJSONObject("fields").getJSONArray("TITLE").getString(0),
            )
            val cover =
                InstrumentationRegistry.getInstrumentation().context.assets.open("cover.png").use {
                    it.readBytes()
                }
            val names =
                arrayOf(
                    "TITLE",
                    "ARTIST",
                    "ALBUM",
                    "GENRE",
                    "LYRICS",
                    "CUSTOM_SONORA",
                    "SONORA_SONG_ABOUT:es",
                    "SONORA_SONG_ABOUT:en",
                )
            val values =
                arrayOf(
                    arrayOf("Canción 🎵"),
                    arrayOf("Björk"),
                    arrayOf("Álbum"),
                    arrayOf("Rock"),
                    arrayOf("[00:00]Primera frase\n[00:01]Última frase completa"),
                    arrayOf("first", "second"),
                    arrayOf("{\"language\":\"es\"}"),
                    arrayOf("{\"language\":\"en\"}"),
                )
            NativeAudio.writeTags(copy.absolutePath, names, values, cover)
            val info = read(copy)
            assertEquals(
                "Canción 🎵",
                info.getJSONObject("fields").getJSONArray("TITLE").getString(0),
            )
            assertEquals("Björk", info.getJSONObject("fields").getJSONArray("ARTIST").getString(0))
            assertEquals(
                "second",
                info.getJSONObject("custom").getJSONArray("CUSTOM_SONORA").getString(1),
            )
            assertEquals(
                "{\"language\":\"es\"}",
                info.getJSONObject("custom").getJSONArray("SONORA_SONG_ABOUT:es").getString(0),
            )
            assertEquals(
                "{\"language\":\"en\"}",
                info.getJSONObject("custom").getJSONArray("SONORA_SONG_ABOUT:en").getString(0),
            )
            ParcelFileDescriptor.open(copy, ParcelFileDescriptor.MODE_READ_ONLY).use {
                assertArrayEquals(cover, NativeAudio.artwork(it.fd, 0, -1, "mp3"))
            }
            fun frames(bytes: ByteArray): ByteArray {
                val start =
                    if (String(bytes, 0, 3) == "ID3")
                        10 + (6..9).fold(0) { v, i -> (v shl 7) or (bytes[i].toInt() and 127) }
                    else 0
                val end =
                    if (bytes.size >= 128 && String(bytes, bytes.size - 128, 3) == "TAG")
                        bytes.size - 128
                    else bytes.size
                return bytes.copyOfRange(start, end)
            }
            assertArrayEquals(frames(original), frames(copy.readBytes()))
            assertArrayEquals(original, source.readBytes())
        } finally {
            source.delete()
            copy.delete()
        }
    }
}
