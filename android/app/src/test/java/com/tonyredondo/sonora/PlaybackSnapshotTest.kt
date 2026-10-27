package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class PlaybackSnapshotTest {
    @Test
    fun restoresQueuePositionAndSelectedPageWithoutAutoplay() {
        val original =
            PlaybackSnapshot(
                listOf("a", "b"),
                "b",
                12500,
                true,
                RepeatMode.ALL,
                PlayerPage.TRANSLATION,
            )
        val restored = PlaybackSnapshot.decode(original.encode())
        assertEquals(original, restored)
        assertFalse(restored.shouldAutoplay)
    }

    @Test
    fun rejectsCorruptQueueRatherThanLosingTheLibrary() {
        assertThrows(IllegalArgumentException::class.java) { PlaybackSnapshot.decode("{broken") }
        assertThrows(IllegalArgumentException::class.java) {
            PlaybackSnapshot.decode("""{"ids":["a"],"current":"missing","position":1}""")
        }
    }

    @Test
    fun clampsAnInvalidSavedPosition() {
        val restored = PlaybackSnapshot.decode("""{"ids":["a"],"current":"a","position":-800}""")
        assertEquals(0L, restored.positionMs)
    }

    @Test
    fun repeatedSongsRestoreTheCorrectOccurrence() {
        val snapshot = PlaybackSnapshot(listOf("a", "b", "a"), "a", 6000, currentIndex = 2)
        assertEquals(2, PlaybackSnapshot.decode(snapshot.encode()).currentIndex)
    }

    @Test
    fun keepsTheChosenPageWhenSwitchingSongs() {
        val saved =
            PlaybackSnapshot(listOf("a", "b"), "a", 0, false, RepeatMode.OFF, PlayerPage.ALBUM)
        assertEquals(PlayerPage.ALBUM, saved.copy(currentId = "b").page)
    }
}
