package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class LyricsRepairTest {
    @Test
    fun unicodeCaseAndPunctuationDoNotCreateUnnecessaryEdits() {
        val original = "[ar:Álvaro]\n[00:01.00]¡Sí, corazón!"
        val review = LyricsRepair(original, transcript("[00:01.00]sí corazón"))
        assertTrue(review.proposals.isEmpty())
        assertEquals(original, review.applying(emptyMap()))
    }

    @Test
    fun internalApostrophesAreWordsAndKeepProviderTiming() {
        for ((originalWord, suggested) in
            listOf("cant" to "can't", "its" to "it's", "lhomme" to "l’homme")) for (timed in
            listOf(true, false)) {
            val text = "We $suggested go home"
            val words =
                text.split(' ').mapIndexed { index, word ->
                    TranscriptWord(word, 1 + index * .4, 1.3 + index * .4)
                }
            val review =
                LyricsRepair(
                    (if (timed) "[00:01]" else "") + "We $originalWord go hume",
                    LyricsTranscript(text, "[00:01]$text", 8.0, words),
                )
            val change = review.proposals.single { it.original == originalWord }
            assertEquals(suggested, change.suggested)
            assertEquals(1.4, change.start!!, .00001)
            assertEquals(1.7, change.end!!, .00001)
            assertEquals(listOf(text), LyricsDocument.parse(accept(review)).lines.map { it.text })
        }
    }

    @Test
    fun additionsOnEitherSideOfAPauseRemainIndependentAndOrdered() {
        for (first in listOf("Bright road", "Bright roan", "bad phrase")) {
            val review =
                LyricsRepair(
                    "[00:01]$first\n[00:03]\n[00:05]We return",
                    transcript(
                        "[00:01]Bright road\n[00:02]New first verse\n[00:02.50]New second verse\n[00:04]New third verse\n[00:05]We return",
                    ),
                )
            val result = LyricsDocument.parse(accept(review))
            assertEquals(
                listOf(
                    "Bright road",
                    "New first verse",
                    "New second verse",
                    "",
                    "New third verse",
                    "We return",
                ),
                result.lines.map { it.text },
            )
            assertEquals(
                listOf(1000L, 2000L, 2500L, 3000L, 4000L, 5000L),
                result.lines.map { it.timeMs },
            )
        }
    }

    @Test
    fun manualUnrecognizedEditsKeepOriginalTimesAndBlankParagraphsDoNotConsumeTimes() {
        val review =
            LyricsRepair(
                "[00:01]Bright road\n[00:02]lost first\n[00:03]lost second\n[00:05]We return",
                transcript("[00:01]Bright road\n[00:05]We return"),
            )
        val proposal = review.proposals.single { it.kind == LyricsRepair.Kind.UNRECOGNIZED }
        val result =
            LyricsDocument.parse(
                review.applying(mapOf(proposal.id to LyricsRepair.Edit("my words\n\nother words"))),
            )
        assertEquals(
            listOf("Bright road", "my words", "other words", "We return"),
            result.lines.map { it.text },
        )
        assertEquals(listOf(1000L, 2000L, 3000L, 5000L), result.lines.map { it.timeMs })
    }

    @Test
    fun invalidOffsetBeforeAValidOffsetUsesTheSameTagAsTheDisplayReader() {
        val original = "[offset:invalid]\n[offset:500]\n[00:01]Bright roan\n[00:03]We return"
        val result =
            LyricsDocument.parse(
                accept(
                    LyricsRepair(
                        original,
                        transcript("[00:00.50]Bright road\n[00:02.50]We return"),
                    ),
                ),
            )
        assertEquals(listOf(500L, 2500L), result.lines.map { it.timeMs })
    }

    @Test
    fun replacementCannotAssembleControlsWithUnchangedSurroundings() {
        for ((original, source, word, edit) in
            listOf(
                listOf("[00:bad]\nWe sing", "[00:01]00 twenty\n[00:03]We sing", "bad", "20"),
                listOf(
                    "[Singer:Guest]\nWe sing",
                    "[00:01]Artist Guest\n[00:03]We sing",
                    "Singer",
                    "ar",
                ),
            )) {
            val review = LyricsRepair(original, transcript(source))
            val change = review.proposals.single { it.original == word }
            try {
                review.applying(mapOf(change.id to LyricsRepair.Edit(edit)))
                fail()
            } catch (_: IllegalArgumentException) {}
        }
    }

    private fun transcript(lrc: String) =
        LyricsTranscript(LyricsDocument.parse(lrc).plainText, lrc, 8.0)

    private fun accept(review: LyricsRepair, onlyCompletions: Boolean = false) =
        review.applying(
            review.proposals
                .filter { it.kind != LyricsRepair.Kind.UNRECOGNIZED }
                .associate { it.id to LyricsRepair.Edit(it.suggested, it.start) },
            onlyCompletions,
        )

    @Test
    fun correctionAndNewVerseCanBeAcceptedIndependently() {
        val source = "[ar:Example]\n[00:00.10]Bright roan\n[00:03.10]We return"
        val review =
            LyricsRepair(
                source,
                transcript("[00:00.10]Bright road\n[00:01.40]Walk beside me\n[00:03.10]We return"),
            )
        assertEquals(1, review.proposals.count { it.kind == LyricsRepair.Kind.CORRECTION })
        assertEquals(1, review.proposals.count { it.kind == LyricsRepair.Kind.COMPLETION })
        assertEquals(
            listOf("Bright road", "Walk beside me", "We return"),
            LyricsDocument.parse(accept(review)).lines.map { it.text },
        )
        assertEquals(
            listOf(100L, 1400L, 3100L),
            LyricsDocument.parse(accept(review)).lines.map { it.timeMs },
        )
        assertEquals(
            listOf("Bright roan", "Walk beside me", "We return"),
            LyricsDocument.parse(accept(review, true)).lines.map { it.text },
        )
        assertTrue(accept(review).contains("[ar:Example]"))
        assertTrue(LyricsDocument.parse(accept(review)).isAIRepaired)
    }

    @Test
    fun omittedOriginalVersesNeverDisappearByAcceptingTheOtherProposals() {
        val original = "Bright road\nKeep this chorus\nWe return"
        val review =
            LyricsRepair(original, transcript("[00:00.10]Bright road\n[00:03.10]We return"))
        assertEquals(original, review.applying(emptyMap()))
        assertEquals(original, accept(review))
        assertTrue(
            review.proposals.any {
                it.kind == LyricsRepair.Kind.UNRECOGNIZED &&
                    it.original.contains("Keep this chorus")
            },
        )
    }

    @Test
    fun completionInsideAPhraseKeepsTheOriginalTimeAndPunctuation() {
        val review = LyricsRepair("[00:01.00]Bright road", transcript("[00:01.00]Bright new road"))
        assertEquals(
            listOf("Bright new road"),
            LyricsDocument.parse(accept(review)).lines.map { it.text },
        )
        assertEquals(1000L, LyricsDocument.parse(accept(review)).lines.single().timeMs)
    }

    @Test
    fun zeroLengthWordsAndTimingCorrectionsAreIndependentFromTextCorrections() {
        val original = "[00:01.00]Here\n[00:02.00]that stays\n[00:04.00]Bright roan"
        val source =
            LyricsTranscript(
                "Here\nthat stays\nBright road",
                "[00:01.00]Here\n[00:01.80]that stays\n[00:04.00]Bright road",
                8.0,
                listOf(
                    TranscriptWord("Here", 1.0, 1.2),
                    TranscriptWord("that", 1.8, 1.9),
                    TranscriptWord("stays", 2.3, 2.5),
                    TranscriptWord("Bright", 4.0, 4.3),
                    TranscriptWord("road", 4.5, 4.5),
                ),
            )
        val review = LyricsRepair(original, source)
        val correction = review.proposals.single { it.kind == LyricsRepair.Kind.CORRECTION }
        assertEquals("road", correction.suggested)
        assertEquals(4.5, correction.end!!, 0.0)
        val textOnly =
            review.applying(mapOf(correction.id to LyricsRepair.Edit(correction.suggested)))
        assertEquals(
            listOf(1000L, 2000L, 4000L),
            LyricsDocument.parse(textOnly).lines.map { it.timeMs },
        )
        assertEquals(
            listOf(1000L, 1800L, 4000L),
            LyricsDocument.parse(accept(review)).lines.map { it.timeMs },
        )
    }

    @Test
    fun repeatedChorusesAndProviderRewrappingKeepTheirOriginalOccurrenceAndLayout() {
        val original = "[00:01]We return\n[00:02]Bright roan\n[00:05]We return\n[00:06]Bright road"
        val review =
            LyricsRepair(
                original,
                transcript("[00:01]We return Bright road\n[00:05]We return Bright road"),
            )
        val result = LyricsDocument.parse(accept(review))
        assertEquals(
            listOf("We return", "Bright road", "We return", "Bright road"),
            result.lines.map { it.text },
        )
        assertEquals(listOf(1000L, 2000L, 5000L, 6000L), result.lines.map { it.timeMs })
    }

    @Test
    fun pauseCuesAndOffsetsSurviveCorrections() {
        val review =
            LyricsRepair(
                "[offset:100]\n[00:01.10]Bright roan\n[00:02.10]\n[00:03.10]We return",
                transcript("[00:01]Bright road\n[00:03]We return"),
            )
        val result = LyricsDocument.parse(accept(review))
        assertEquals(listOf("Bright road", "", "We return"), result.lines.map { it.text })
        assertEquals(listOf(1000L, 2000L, 3000L), result.lines.map { it.timeMs })
    }

    @Test
    fun mixedTimingUnknownSelectionsAndComposedLrcControlsAreRejected() {
        try {
            LyricsRepair(
                "[00:01]Hello\nUntimed words",
                transcript("[00:01]Hello\n[00:02]Untimed words"),
            )
            fail()
        } catch (_: IllegalArgumentException) {}
        val review = LyricsRepair("[00:01]Bright roan", transcript("[00:01]Bright road"))
        try {
            review.applying(mapOf(999 to LyricsRepair.Edit("x")))
            fail()
        } catch (_: IllegalArgumentException) {}
        val change = review.proposals.single { it.kind == LyricsRepair.Kind.CORRECTION }
        try {
            review.applying(mapOf(change.id to LyricsRepair.Edit("[00:03]Injected")))
            fail()
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun insertionTimesMustStayBetweenTheirNeighbors() {
        val review =
            LyricsRepair(
                "[00:01]Here\n[00:03]We return",
                transcript("[00:01]Here\n[00:02]New words\n[00:03]We return"),
            )
        val addition = review.proposals.single { it.kind == LyricsRepair.Kind.COMPLETION }
        try {
            review.applying(mapOf(addition.id to LyricsRepair.Edit(addition.suggested, 4.0)))
            fail()
        } catch (error: LyricsRepair.TimingIssue) {
            assertTrue(addition.id in error.proposalIds)
        }
    }
}
