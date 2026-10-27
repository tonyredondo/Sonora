package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PlaylistSafExportTest {
    @Test
    fun realDocumentsProviderKeepsTracksDirectlyInTheChosenFolder() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val owned =
            context.contentResolver.persistedUriPermissions.firstOrNull {
                it.isReadPermission &&
                    it.isWritePermission &&
                    runCatching {
                            DocumentsContract.getTreeDocumentId(it.uri) ==
                                "primary:Download/Sonora_QA_20261025"
                        }
                        .getOrDefault(false)
            }
                ?: error(
                    "The owned Sonora QA SAF folder must be selected with read/write access before this test.",
                )
        val root = DocumentFile.fromTreeUri(context, owned.uri)!!
        val id = UUID.randomUUID().toString()
        val directory = root.createDirectory("Export-QA-$id")!!
        val database = "saf-export-$id.sqlite"
        val store = LibraryStore(context, database)
        val source = File(context.cacheDir, "saf-$id.wav")
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use {
                input ->
                source.outputStream().use(input::copyTo)
            }
            val song =
                LocalAudio(context)
                    .read(Uri.fromFile(source))
                    .copy(
                        title = "SAF QA",
                        artist = "Sonora Tests",
                        lyricsText = "[00:00]A complete phrase",
                    )
            for (format in PlaylistExportFormat.entries) {
                val result =
                    PlaylistExporter(context, store)
                        .exportToFolder(listOf(song), "QA $format", directory, format)
                val manifest = directory.findFile(result.playlistName) ?: error("Missing manifest")
                val text =
                    context.contentResolver.openInputStream(manifest.uri)!!.use {
                        it.readBytes().toString(Charsets.UTF_8)
                    }
                val name = text.lines().single { it.isNotBlank() && !it.startsWith('#') }
                val document = directory.findFile(name) ?: error("Missing track $name")
                assertEquals("SAF QA", LocalAudio(context).read(document.uri).title)
                assertEquals(song.lyricsText, LocalAudio(context).read(document.uri).lyricsText)
            }
            assertEquals(4, directory.listFiles().size)
            assertFalse(directory.listFiles().any { it.isDirectory })
        } finally {
            source.delete()
            store.close()
            context.deleteDatabase(database)
            check(directory.delete())
        }
    }
}
