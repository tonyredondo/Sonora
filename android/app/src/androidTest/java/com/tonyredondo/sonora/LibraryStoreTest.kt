package com.tonyredondo.sonora

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryStoreTest {
    @Test
    fun libraryPlaylistOrderAndQueueSurviveReopeningWithoutAutoplay() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "qa-${UUID.randomUUID()}.db"
        try {
            LibraryStore(context, name).use { store ->
                store.saveSongs(
                    listOf(Song("a", "content://qa/a", "One"), Song("b", "content://qa/b", "Two")),
                )
                val playlist = store.createPlaylist("November")
                store.setPlaylistSongs(playlist, listOf("b", "a", "b"))
                store.saveSnapshot(
                    PlaybackSnapshot(
                        listOf("b", "a", "b"),
                        "b",
                        22000,
                        true,
                        RepeatMode.ALL,
                        PlayerPage.TRANSLATION,
                        2,
                    ),
                )
            }
            LibraryStore(context, name).use { reopened ->
                assertEquals(listOf("a", "b"), reopened.songs().map { it.id }.sorted())
                assertEquals(listOf("b", "a", "b"), reopened.playlists().single().songIds)
                val restored = reopened.snapshot()!!
                assertEquals(2, restored.currentIndex)
                assertEquals(22000L, restored.positionMs)
                assertFalse(restored.shouldAutoplay)
                assertEquals(PlayerPage.TRANSLATION, restored.page)
            }
        } finally {
            context.deleteDatabase(name)
        }
    }

    @Test
    fun openWithKeepsOnlyAReferenceAndNeverImportsOrDeletesSourceAudio() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "qa-${UUID.randomUUID()}.db"
        val source = java.io.File(context.cacheDir, "qa-${UUID.randomUUID()}.wav")
        val bytes = byteArrayOf(1, 2, 3, 4)
        source.writeBytes(bytes)
        try {
            LibraryStore(context, name).use { store ->
                store.saveSongs(
                    listOf(Song("external", source.toURI().toString(), "External")),
                    inLibrary = false,
                )
                assertTrue(store.songs().isEmpty())
                assertNotNull(store.song("external"))
                assertArrayEquals(bytes, source.readBytes())
                store.removeSongs(listOf("external"))
                assertArrayEquals(bytes, source.readBytes())
            }
        } finally {
            context.deleteDatabase(name)
            source.delete()
        }
    }

    @Test
    fun invalidPlaylistUpdateIsAtomicAndCannotLoseExistingOrder() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "qa-${UUID.randomUUID()}.db"
        try {
            LibraryStore(context, name).use { store ->
                store.saveSongs(listOf(Song("a", "content://qa/a", "One")))
                val playlist = store.createPlaylist("Keep")
                store.setPlaylistSongs(playlist, listOf("a"))
                assertThrows(IllegalArgumentException::class.java) {
                    store.setPlaylistSongs(playlist, listOf("missing"))
                }
                assertEquals(listOf("a"), store.playlists().single().songIds)
            }
        } finally {
            context.deleteDatabase(name)
        }
    }
}
