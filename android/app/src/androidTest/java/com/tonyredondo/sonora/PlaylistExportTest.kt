package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PlaylistExportTest {
    @Test
    fun convertedAudioPreservesEveryEmbeddedPicture() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = "pictures-${UUID.randomUUID()}.sqlite"
        val store = LibraryStore(context, database)
        val root = File(context.cacheDir, "picture-qa-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.flac")
        try {
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("multiple-covers.flac")
                .use { input -> source.outputStream().use(input::copyTo) }
            val original = source.readBytes()
            val song =
                LocalAudio(context)
                    .read(Uri.fromFile(source))
                    .copy(title = "Picture preservation QA")
            val output = File(root, "out").apply { mkdirs() }
            val result =
                PlaylistExporter(context, store)
                    .export(
                        listOf(song),
                        "Pictures",
                        Uri.fromFile(output),
                        PlaylistExportFormat.MP3,
                    )
            val name =
                File(output, result.playlistName).readLines().single {
                    it.isNotBlank() && !it.startsWith('#')
                }
            val file = File(output, name)
            assertTrue(file.length() > 0)
            // The host independently inspects both attached pictures with ffprobe.
            file.copyTo(File(context.cacheDir, "qa-multiple-covers.mp3"), overwrite = true)
            android.os.ParcelFileDescriptor.open(
                    source,
                    android.os.ParcelFileDescriptor.MODE_READ_ONLY,
                )
                .use { descriptor ->
                    val copy = File(root, "copy.mp3")
                    file.copyTo(copy)
                    assertEquals(
                        2,
                        NativeAudio.copyPictures(descriptor.fd, 0, -1, "flac", copy.absolutePath),
                    )
                }
            assertArrayEquals(original, source.readBytes())
        } finally {
            store.close()
            context.deleteDatabase(database)
            root.deleteRecursively()
        }
    }

    @Test
    fun originalsAndMp3AreDirectPortableAndPreserveSourcesAndExistingDestinationFiles() =
        runBlocking {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val id = UUID.randomUUID().toString()
            val database = "export-$id.sqlite"
            val store = LibraryStore(context, database)
            val root = File(context.cacheDir, "export-qa-$id").apply { mkdirs() }
            try {
                fun fixture(asset: String): File =
                    File(root, asset).also { target ->
                        InstrumentationRegistry.getInstrumentation()
                            .context
                            .assets
                            .open(asset)
                            .use { input -> target.outputStream().use(input::copyTo) }
                    }
                val mp3 = fixture("replaygain.mp3")
                val wav = fixture("fixture.wav")
                val originals = mapOf(mp3 to mp3.readBytes(), wav to wav.readBytes())
                val reader = LocalAudio(context)
                val songs =
                    listOf(
                        reader
                            .read(Uri.fromFile(mp3))
                            .copy(lyricsText = "[00:00]Hello\n[00:01]A whole last phrase"),
                        reader
                            .read(Uri.fromFile(wav))
                            .copy(
                                title = "Wave Song",
                                artist = "Sonora QA",
                                album = "QA",
                                lyricsText = "[00:00]First phrase\n[00:01]Last phrase",
                            ),
                    )
                for (song in songs) for (language in listOf("es", "en")) PortableInterpretations
                    .remember(
                        store,
                        song,
                        language,
                        false,
                        JSONObject()
                            .put("explanation", "About $language")
                            .put("model", "gpt-6-astra")
                            .put("effort", "medium"),
                    )
                for (format in PlaylistExportFormat.entries) {
                    val destination = File(root, format.name).apply { mkdirs() }
                    val sentinel =
                        File(destination, "01 - ReplayGain QA.mp3").apply {
                            writeText("Existing destination")
                        }
                    val result =
                        PlaylistExporter(context, store)
                            .export(
                                songs + songs.take(1),
                                "QA Playlist",
                                Uri.fromFile(destination),
                                format,
                            )
                    assertEquals(3, result.files)
                    assertEquals("Existing destination", sentinel.readText())
                    assertFalse(destination.listFiles()!!.any { it.isDirectory })
                    val manifest = File(destination, result.playlistName).readText()
                    val names = manifest.lines().filter { it.isNotBlank() && !it.startsWith('#') }
                    assertEquals(3, names.size)
                    assertEquals(3, names.distinct().size)
                    assertEquals(
                        5,
                        destination.listFiles()!!.size,
                    ) // three tracks, manifest, pre-existing sentinel
                    names.forEachIndexed { index, name ->
                        val file = File(destination, name)
                        assertTrue(file.length() > 0)
                        val imported = reader.read(Uri.fromFile(file))
                        assertEquals(songs[index % 2].title, imported.title)
                        assertEquals(songs[index % 2].lyricsText, imported.lyricsText)
                        assertEquals(
                            "About es",
                            PortableInterpretations.explanation(
                                PortableInterpretations.embedded(imported, "es", false)!!,
                            ),
                        )
                        assertEquals(
                            "About en",
                            PortableInterpretations.explanation(
                                PortableInterpretations.embedded(imported, "en", false)!!,
                            ),
                        )
                        if (format == PlaylistExportFormat.MP3) assertTrue(imported.durationMs > 0)
                    }
                }
                for ((file, bytes) in originals) assertArrayEquals(bytes, file.readBytes())
                val cancel = File(root, "cancel").apply { mkdirs() }
                val retained = File(cancel, "keep.txt").apply { writeText("keep") }
                try {
                    PlaylistExporter(context, store).export(
                        songs,
                        "Canceled",
                        Uri.fromFile(cancel),
                        PlaylistExportFormat.ORIGINAL,
                    ) {
                        if (it.startsWith("Guardando 2"))
                            throw CancellationException("QA cancellation")
                    }
                    fail("Expected cancellation")
                } catch (_: CancellationException) {}
                assertEquals(listOf(retained.name), cancel.listFiles()!!.map { it.name })
                assertFalse(
                    context.cacheDir.listFiles()!!.any { it.name.startsWith("playlist-export-") },
                )
            } finally {
                store.close()
                context.deleteDatabase(database)
                root.deleteRecursively()
            }
        }
}
