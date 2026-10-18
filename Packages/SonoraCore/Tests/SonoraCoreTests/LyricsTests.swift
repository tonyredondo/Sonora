import XCTest
@testable import SonoraCore

final class LyricsTests: XCTestCase {
    func testAIAttributionSurvivesParsingAndCueSlicingWithoutBecomingALyric() {
        let body = "[00:01]Hello\n[00:03]Again"
        let original = LyricsDocument(text: body)
        let generated = LyricsDocument(text: "[by:Sonora AI transcription - ElevenLabs]\n" + body)
        XCTAssertEqual(generated.lines, original.lines)
        XCTAssertNotEqual(generated, original, "AI origin is part of the displayed document")
        XCTAssertNotEqual(generated.sliced(from: 1, duration: 3), original.sliced(from: 1, duration: 3))
        XCTAssertEqual(LyricsDocument(text: "[by:Someone else]\n" + body), original)
    }

    func testActiveLineAnticipatesTimestampsBy250Milliseconds() {
        let lyrics = LyricsDocument(text: "[00:01]Primera\n[00:03]Segunda")
        XCTAssertNil(lyrics.activeLine(at: 0.749))
        XCTAssertEqual(lyrics.activeLine(at: 0.75), 0)
        XCTAssertEqual(lyrics.activeLine(at: 1), 0)
        XCTAssertEqual(lyrics.activeLine(at: 2.749), 0)
        XCTAssertEqual(lyrics.activeLine(at: 2.75), 1)
        XCTAssertEqual(lyrics.activeLine(at: 30), 1)
        XCTAssertEqual(lyrics.activeLine(at: 1.5), 0, "Seeking backwards must restore the earlier phrase")
        XCTAssertNil(lyrics.activeLine(at: 0.5))
        XCTAssertEqual(lyrics.lines.map(\.time), [1, 3], "Visual anticipation must preserve seek and saved timestamps")
    }

    func testAnticipationCombinesWithManualAndFileOffsets() {
        let lyrics = LyricsDocument(text: "[offset:+500]\n[00:01.50]Primera\n[00:03.50]Segunda")
        XCTAssertEqual(lyrics.lines.map(\.time), [1, 3])
        XCTAssertNil(lyrics.activeLine(at: 1.749, offset: 1))
        XCTAssertEqual(lyrics.activeLine(at: 1.75, offset: 1), 0)
        XCTAssertEqual(lyrics.activeLine(at: 3.749, offset: 1), 0)
        XCTAssertEqual(lyrics.activeLine(at: 3.75, offset: 1), 1)
        XCTAssertEqual(lyrics.activeLine(at: 0, offset: -1), 0)
        XCTAssertEqual(lyrics.activeLine(at: 1.749, offset: -1), 0)
        XCTAssertEqual(lyrics.activeLine(at: 1.75, offset: -1), 1)
        XCTAssertNil(lyrics.activeLine(at: .nan))
        XCTAssertNil(lyrics.activeLine(at: .infinity))
        XCTAssertNil(lyrics.activeLine(at: 2, offset: .nan))
    }

    func testMultipleTimestampsUnicodeAndFileOffset() {
        let lyrics = LyricsDocument(text: "[ar:Sonora]\n[offset:+500]\n[00:01.20][00:03.200]Canción 🌙\n[00:02]Otra línea")
        XCTAssertEqual(lyrics.lines.map(\.text), ["Canción 🌙", "Otra línea", "Canción 🌙"])
        XCTAssertEqual(lyrics.lines.map(\.time), [0.7, 1.5, 2.7])
        XCTAssertNil(lyrics.activeLine(at: 0.2))
        XCTAssertEqual(lyrics.activeLine(at: 1.6), 1)
        XCTAssertEqual(lyrics.activeLine(at: 1.6, offset: 1), 0)
    }

    func testPlainAndMalformedLyricsHaveNoSeekingTimes() {
        let lyrics = LyricsDocument(text: "[ar:Sonora]\r\nUna línea\r\n[99:90]No es un tiempo\r\nOtra línea")
        XCTAssertFalse(lyrics.isTimed)
        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertNil(lyrics.activeLine(at: 500))
        XCTAssertTrue(LyricsDocument(text: "  \n[ti:Solo título]").lines.isEmpty)
    }
}
