import XCTest
@testable import SonoraCore

final class LyricsTests: XCTestCase {
    func testMultipleTimestampsUnicodeAndFileOffset() {
        let lyrics = LyricsDocument(text: "[ar:Sonora]\n[offset:+500]\n[00:01.20][00:03.200]Canción 🌙\n[00:02]Otra línea")
        XCTAssertEqual(lyrics.lines.map(\.text), ["Canción 🌙", "Otra línea", "Canción 🌙"])
        XCTAssertEqual(lyrics.lines.map(\.time), [0.7, 1.5, 2.7])
        XCTAssertNil(lyrics.activeLine(at: 0.2))
        XCTAssertEqual(lyrics.activeLine(at: 1.6), 1)
        XCTAssertEqual(lyrics.activeLine(at: 1.6, offset: 1), nil)
    }

    func testPlainAndMalformedLyricsHaveNoSeekingTimes() {
        let lyrics = LyricsDocument(text: "[ar:Sonora]\r\nUna línea\r\n[99:90]No es un tiempo\r\nOtra línea")
        XCTAssertFalse(lyrics.isTimed)
        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertNil(lyrics.activeLine(at: 500))
        XCTAssertTrue(LyricsDocument(text: "  \n[ti:Solo título]").lines.isEmpty)
    }
}
