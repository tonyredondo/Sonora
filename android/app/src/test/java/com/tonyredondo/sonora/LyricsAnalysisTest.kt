package com.tonyredondo.sonora

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LyricsAnalysisTest {
    private val digest = "a".repeat(64)

    private fun response() =
        JSONObject()
            .put("plain_lyrics", "Hello\nbright road")
            .put("synced_lyrics", "[00:00.20]Hello\n[00:01.30]bright road")
            .put("audio_sha256", digest)
            .put("duration", 3.0)
            .put("model_id", "scribe_v2")
            .put(
                "words",
                JSONArray()
                    .put(JSONObject().put("text", "Hello").put("start", .2).put("end", .8))
                    .put(JSONObject().put("text", "bright").put("start", 1.3).put("end", 1.5))
                    .put(JSONObject().put("text", "road").put("start", 1.8).put("end", 1.8)),
            )

    @Test
    fun transcriptBindsAudioAndEveryWordAndAcceptsZeroLengthWords() {
        val transcript = LyricsTranscript.decode(response(), digest, 3.0)!!
        assertEquals(3, transcript.words!!.size)
        assertEquals("bright road", LyricsDocument.parse(transcript.syncedText).lines[1].text)
        assertEquals(1.8, transcript.words.last().end, 0.0)
        val empty =
            response().put("plain_lyrics", "").put("synced_lyrics", "").put("words", JSONArray())
        assertNull(LyricsTranscript.decode(empty, digest, 3.0))
    }

    @Test
    fun invalidAudioTextWordAndTimeResponsesAreRejected() {
        val bad =
            listOf(
                response().put("audio_sha256", "b".repeat(64)),
                response().put("duration", 4),
                response().put("model_id", "unknown"),
                response().put("synced_lyrics", "[00:00.20]Hello\n[00:01.30]a different sentence"),
                response().put("synced_lyrics", "[00:01.30]Hello\n[00:00.20]bright road"),
                response().also { it.getJSONArray("words").getJSONObject(1).put("start", 4) },
                response().also { it.getJSONArray("words").getJSONObject(1).put("text", "wrong") },
            )
        for (value in bad) try {
            LyricsTranscript.decode(value, digest, 3.0)
            fail(value.toString())
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun alignmentRetainsTheExactOriginalPhraseLayoutAndPunctuation() {
        val original = "  Hello!\n\nBright road…"
        val result = alignedLyrics("[00:00.20]hello\n[00:01.30]bright road", original, 3.0)
        assertEquals(
            listOf("Hello!", "Bright road…"),
            LyricsDocument.parse(result).lines.map { it.text },
        )
        assertEquals(listOf(200L, 1300L), LyricsDocument.parse(result).lines.map { it.timeMs })
        for (text in
            listOf(
                "[00:00.20]hello bright road",
                "[00:00.20]hello\n[00:03.10]bright road",
                "[00:00.20]hello\nThis line has no time",
            )) try {
            alignedLyrics(text, original, 3.0)
            fail(text)
        } catch (_: IllegalArgumentException) {}
    }
}
