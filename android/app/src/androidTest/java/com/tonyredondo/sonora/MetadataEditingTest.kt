package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class MetadataEditingTest {
    @Test
    fun editsAreExplicitGuardedRetainedOnRescanAndDoNotTouchSourceAudio() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = "metadata-edit-${UUID.randomUUID()}.sqlite"
        val store = LibraryStore(context, database)
        val file = File(context.cacheDir, "metadata-${UUID.randomUUID()}.mp3")
        try {
            InstrumentationRegistry.getInstrumentation()
                .context
                .assets
                .open("replaygain.mp3")
                .use { input -> file.outputStream().use(input::copyTo) }
            val bytes = file.readBytes()
            val song = LocalAudio(context).read(Uri.fromFile(file))
            store.saveSongs(listOf(song))
            val list = store.createPlaylist("Metadata QA")
            store.setPlaylistSongs(list, listOf(song.id, song.id))
            val draft = MetadataDraft("Edited 🎵", "Artist", "Album", "Rock", 7)
            store.updateMetadata(song, draft)
            val edited = store.song(song.id)!!
            assertEquals(draft, MetadataDraft.from(edited))
            store.saveSongs(listOf(LocalAudio(context).read(Uri.fromFile(file))))
            assertEquals(draft, MetadataDraft.from(store.song(song.id)!!))
            assertEquals(listOf(song.id, song.id), store.playlists().single().songIds)
            try {
                store.updateMetadata(song, draft.copy(title = "Stale"))
                fail("Expected conflict")
            } catch (_: IllegalStateException) {}
            assertArrayEquals(bytes, file.readBytes())
            store.saveSongs(listOf(song.copy(modified = song.modified + 1)))
            assertEquals(song.title, store.song(song.id)!!.title)
        } finally {
            store.close()
            context.deleteDatabase(database)
            file.delete()
        }
    }
}
