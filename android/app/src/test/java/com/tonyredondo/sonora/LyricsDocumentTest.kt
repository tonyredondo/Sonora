package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class LyricsDocumentTest {
    @Test
    fun lrcOffsetsRepeatedTimestampsAndStableLineIdsMatchTheExistingApp() {
        val lyrics =
            LyricsDocument.parse(
                "[ar:Artist]\n[offset:1000]\n[00:02.50][00:04.500]Same phrase\n[00:09]Last phrase",
            )
        assertTrue(lyrics.isTimed)
        assertEquals(listOf(1500L, 3500L, 8000L), lyrics.lines.map { it.timeMs })
        assertEquals(listOf(0, 1, 2), lyrics.lines.map { it.id })
        assertEquals(
            listOf("Same phrase", "Same phrase", "Last phrase"),
            lyrics.lines.map { it.text },
        )
        assertNull(lyrics.activeLine(0))
        assertEquals(0, lyrics.activeLine(1250))
        assertEquals(2, lyrics.activeLine(9000))
        assertEquals(1, lyrics.activeLine(8500, userOffsetMs = 1000))
    }

    @Test
    fun plainLyricsKeepWholePhrasesAndHideProvenanceMarkers() {
        val lyrics =
            LyricsDocument.parse(
                "[by:Sonora AI transcription - ElevenLabs]\nA complete phrase\n\nAnother phrase",
            )
        assertFalse(lyrics.isTimed)
        assertTrue(lyrics.isAITranscribed)
        assertEquals(listOf("A complete phrase", "Another phrase"), lyrics.lines.map { it.text })
        assertNull(lyrics.activeLine(5000))
    }
}
