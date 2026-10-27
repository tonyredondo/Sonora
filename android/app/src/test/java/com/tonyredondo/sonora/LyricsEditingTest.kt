package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class LyricsEditingTest {
    @Test
    fun canonicalTimingPreservesHeadersWholePhrasesAndAppliedFileOffset() {
        val source =
            "[ar:QA Artist]\n[by:Sonora AI transcription - ElevenLabs]\n[offset:1000]\n[00:02.25]A complete long phrase\n[00:09]The final phrase"
        val draft = LyricsDraft.from(source)
        val saved = draft.serialize()
        assertTrue(saved.contains("[ar:QA Artist]"))
        assertFalse(saved.contains("[offset:"))
        val parsed = LyricsDocument.parse(saved)
        assertEquals(listOf(1250L, 8000L), parsed.lines.map { it.timeMs })
        assertEquals(
            listOf("A complete long phrase", "The final phrase"),
            parsed.lines.map { it.text },
        )
        assertTrue(parsed.isAITranscribed)
    }

    @Test
    fun mixedTimedAndUntimedPhrasesCannotBeSilentlyDroppedOrSavedPartially() {
        val draft =
            LyricsDraft.from(
                "[00:01]First complete phrase\nSecond complete phrase\n[00:03]Third complete phrase",
            )
        assertEquals(3, draft.lines.size)
        assertThrows(IllegalArgumentException::class.java) { draft.serialize() }
        val fixed = draft.mark(1, 2000)
        assertEquals(
            listOf("First complete phrase", "Second complete phrase", "Third complete phrase"),
            LyricsDocument.parse(fixed.serialize()).lines.map { it.text },
        )
        assertThrows(IllegalArgumentException::class.java) { fixed.mark(1, 4000) }
        assertFalse(LyricsDocument.parse(draft.clearTiming().serialize()).isTimed)
    }

    @Test
    fun phraseLoopsHandleSharedTimestampsLastLineAndUserOffset() {
        val document =
            LyricsDocument.parse("[00:01]First voice\n[00:01]Second voice\n[00:05]Last phrase")
        assertEquals(LoopRegion("track", 1500, 5500), phraseLoop("track", document, 0, 10000, 500))
        assertEquals(LoopRegion("track", 5500, 10000), phraseLoop("track", document, 2, 10000, 500))
        assertThrows(IllegalArgumentException::class.java) {
            phraseLoop("track", document, 2, 4000, 0)
        }
    }

    @Test
    fun markerAndOffsetStateRoundTripWithoutChangingLyrics() {
        val value =
            SongTools(
                1250,
                listOf(SongMarker("one", "Estribillo", 34000), SongMarker("two", "Solo", 88000)),
            )
        assertEquals(value, SongTools.decode(value.encode()))
        assertThrows(IllegalArgumentException::class.java) { SongTools(6000).validate() }
        assertThrows(IllegalArgumentException::class.java) {
            SongTools(markers = listOf(SongMarker("one", "Bad\nname", 1))).validate()
        }
    }
}
