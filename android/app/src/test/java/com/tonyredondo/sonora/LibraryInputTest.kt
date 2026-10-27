package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class LibraryInputTest {
    @Test
    fun sortsNumberedFilesNaturallyWithoutIntegerOverflow() {
        val names =
            listOf(
                "Track 10.flac",
                "track 2.flac",
                "Track 1.flac",
                "Track 9999999999999999999999999.flac",
            )
        assertEquals(
            listOf(
                "Track 1.flac",
                "track 2.flac",
                "Track 10.flac",
                "Track 9999999999999999999999999.flac",
            ),
            names.sortedWith(::compareNatural),
        )
    }

    @Test
    fun externalFilesCannotBecomeNetworkOrExecutableUris() {
        assertTrue(validLocalAudioUri("content://provider/document/music%3Aone.mp3"))
        assertTrue(validLocalAudioUri("file:///storage/one.mp3"))
        assertFalse(validLocalAudioUri("https://example.com/private"))
        assertFalse(validLocalAudioUri("file://remote-host/one.mp3"))
        assertFalse(validLocalAudioUri("intent:one"))
    }
}
