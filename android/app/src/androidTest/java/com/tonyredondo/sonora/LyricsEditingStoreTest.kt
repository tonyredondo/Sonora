package com.tonyredondo.sonora

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class LyricsEditingStoreTest {
    @Test
    fun savedLyricsSurviveReopenAndMetadataReloadWithoutImportingOrChangingAudio() {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val id = "lyric-save-${UUID.randomUUID()}"
        val file = File(app.cacheDir, "$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input
            ->
            file.outputStream().use(input::copyTo)
        }
        val originalBytes = contentDigest(file.readBytes())
        val original =
            Song(
                id,
                Uri.fromFile(file).toString(),
                "Lyrics save QA",
                lyricsText = "[00:01]Old phrase",
                durationMs = 30000,
                size = file.length(),
                modified = file.lastModified(),
            )
        val replacement = "[00:01]Edited whole phrase\n[00:10]Final whole phrase"
        var store = LibraryStore(app)
        val before = store.songs().map { it.id }
        try {
            store.saveSongs(listOf(original), inLibrary = false)
            store.updateLyrics(original, replacement)
            assertThrows(IllegalStateException::class.java) {
                store.updateLyrics(original, "Stale edit")
            }
            store.close()
            store = LibraryStore(app)
            assertEquals(replacement, store.song(id)?.lyricsText)
            store.saveSongs(listOf(original), inLibrary = false)
            assertEquals(replacement, store.song(id)?.lyricsText)
            assertEquals(before, store.songs().map { it.id })
            assertEquals(originalBytes, contentDigest(file.readBytes()))
        } finally {
            store.removeSongs(listOf(id))
            store.close()
            file.delete()
        }
    }

    @Test
    fun explicitEmptyLyricsAreRetainedInsteadOfBeingFilledByAutomaticLookup() {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val id = "lyric-empty-${UUID.randomUUID()}"
        val store = LibraryStore(app)
        val source =
            Song(
                id,
                "content://lyric-empty/$id",
                "Explicit empty QA",
                lyricsText = "Original phrase",
            )
        try {
            store.saveSongs(listOf(source), inLibrary = false)
            store.updateLyrics(source, "")
            store.saveSongs(
                listOf(source.copy(lyricsText = "Late lookup result")),
                inLibrary = false,
            )
            assertEquals("", store.song(id)?.lyricsText)
            assertTrue(store.song(id)!!.hasLyricsOverride())
        } finally {
            store.removeSongs(listOf(id))
            store.close()
        }
    }

    @Test
    fun editorRejectsAnAudioSourceThatChangedWithoutChangingItsLyrics() {
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val id = "lyric-changed-${UUID.randomUUID()}"
        val store = LibraryStore(app)
        val source =
            Song(
                id,
                "content://lyric-change/$id",
                "Changed audio QA",
                lyricsText = "Same lyrics",
                size = 100,
                modified = 100,
            )
        try {
            store.saveSongs(listOf(source), inLibrary = false)
            store.saveSongs(listOf(source.copy(size = 200, modified = 200)), inLibrary = false)
            assertThrows(IllegalStateException::class.java) {
                store.updateLyrics(source, "An edit made against the old audio")
            }
        } finally {
            store.removeSongs(listOf(id))
            store.close()
        }
    }
}
