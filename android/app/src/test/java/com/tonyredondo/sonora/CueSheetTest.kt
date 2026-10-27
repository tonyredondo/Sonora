package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class CueSheetTest {
    @Test
    fun parsesPerTrackTagsAndCdFrameBoundariesAcrossTwoFiles() {
        val text =
            """
            PERFORMER "Album Artist"
            TITLE "Complete Album"
            REM GENRE "Alternative Rock"
            FILE "../Disc One.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Opening"
                INDEX 00 00:00:00
                INDEX 01 00:00:01
              TRACK 02 AUDIO
                TITLE "Second phrase"
                PERFORMER "Guest Artist"
                INDEX 01 01:02:37
            FILE "../Disc Two.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
            """
                .trimIndent()
        val tracks =
            CueSheet.parse(
                text.toByteArray(),
                "sheets/album.cue",
                setOf("Disc One.wav", "Disc Two.flac"),
            )
        assertEquals(3, tracks.size)
        assertEquals("Disc One.wav", tracks[0].path)
        assertEquals(1, tracks[0].startCDFrame)
        assertEquals(4687, tracks[0].endCDFrame)
        assertEquals("Opening", tracks[0].title)
        assertEquals("Album Artist", tracks[0].artist)
        assertEquals("Guest Artist", tracks[1].artist)
        assertEquals("Complete Album", tracks[2].album)
        assertEquals("Alternative Rock", tracks[2].genre)
        assertEquals("Pista 3", tracks[2].title)
        assertNull(tracks[1].endCDFrame)
        assertEquals(0, tracks[2].startCDFrame)
    }

    @Test
    fun rejectsEscapedPathsMissingFilesBrokenIndexesAndSyntheticSilence() {
        val good = "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00"
        for (text in
            listOf(
                good.replace("album.wav", "../album.wav"),
                good.replace("album.wav", "/album.wav"),
                good.replace("album.wav", "file:album.wav"),
                good.replace("00:00:00", "00:00:75"),
                good.replace("INDEX 01", "INDEX 00"),
                good + "\nINDEX 01 00:01:00",
                good + "\nTRACK 02 AUDIO\nINDEX 01 00:00:00",
                good + "\nPREGAP 00:02:00",
                good.replace("album.wav", "missing.wav"),
                good.replace("AUDIO", "MODE1/2352"),
            )) {
            try {
                CueSheet.parse(text.toByteArray(), "album.cue", setOf("album.wav"))
                fail(text)
            } catch (_: IllegalArgumentException) {}
        }
    }

    @Test
    fun traditionalWindowsCueAndBomTextKeepAccents() {
        val text =
            "PERFORMER \"Björk\"\r\nFILE \"disc.wav\" WAVE\r\nTRACK 01 AUDIO\r\nTITLE \"Canción\"\r\nINDEX 01 00:00:00"
        for (bytes in
            listOf(
                text.toByteArray(java.nio.charset.Charset.forName("windows-1252")),
                byteArrayOf(-1, -2) + text.toByteArray(Charsets.UTF_16LE),
            )) {
            val track = CueSheet.parse(bytes, "disc.cue", setOf("disc.wav")).single()
            assertEquals("Björk", track.artist)
            assertEquals("Canción", track.title)
        }
    }

    @Test
    fun adjacentSegmentsRoundToTheSamePcmBoundaryAndDoNotShareAnalysisOrOverrides() {
        val first = CueSegment("file:///disc.cue", 1, 1, 76)
        val second = CueSegment("file:///disc.cue", 2, 76, null)
        assertEquals(588L, first.startFrame(44100))
        assertEquals(44688L, first.endFrame(44100, 100000))
        assertEquals(44688L, second.startFrame(44100))
        val song = Song("id", "file:///disc.wav", "Disc", durationMs = 3000)
        val a = first.applyTo(song)
        val b = second.applyTo(song)
        assertNotEquals(a.id, b.id)
        assertNotEquals(audioSourceKey(a), audioSourceKey(b))
        assertNotEquals(lyricSourceRevision(a), lyricSourceRevision(b))
        val changed = first.copy(sheetRevision = "a".repeat(64)).applyTo(song)
        assertEquals(a.id, changed.id)
        assertEquals(audioSourceKey(a), audioSourceKey(changed))
        assertNotEquals(lyricSourceRevision(a), lyricSourceRevision(changed))
    }

    @Test
    fun absentCueTagsKeepEmbeddedAlbumInformationAndInvalidStoredRangesFail() {
        val base =
            Song(
                "id",
                "file:///disc.wav",
                "Whole disc",
                artist = "Embedded artist",
                album = "Embedded album",
                genre = "Rock",
                durationMs = 3000,
            )
        val track =
            CueSheet.parse(
                    "FILE \"disc.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00".toByteArray(),
                    "disc.cue",
                    setOf("disc.wav"),
                )
                .single()
                .song(base, "file:///disc.cue")
        assertEquals("Embedded artist", track.artist)
        assertEquals("Embedded album", track.album)
        assertEquals("Rock", track.genre)
        val invalid =
            org.json.JSONObject(track.metadata).also { it.getJSONObject("cue").put("start", .5) }
        try {
            track.copy(metadata = invalid.toString()).cueSegment()
            fail("Fractional CD frames must not be truncated")
        } catch (_: IllegalArgumentException) {}
    }
}
