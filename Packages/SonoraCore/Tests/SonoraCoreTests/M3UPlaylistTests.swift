import Foundation
import XCTest
@testable import SonoraCore

final class M3UPlaylistTests: XCTestCase {
    func testExtendedUnicodeBOMCRLFAndVlcIntervalsKeepOrder() throws {
        let text = "\u{feff}#EXTM3U\r\n#EXTINF:12,José — Directo\r\nCD 1/Canción.flac\r\n#EXTINF:1,Final\r\n#EXTVLCOPT:start-time=1.013333\r\n#EXTVLCOPT:stop-time=2.0\r\nLive.wav\r\n"
        let list = try M3UPlaylist.decode(Data(text.utf8), utf8Only: true)
        XCTAssertEqual(list.entries.map(\.path), ["CD 1/Canción.flac", "Live.wav"])
        XCTAssertEqual(list.entries.first?.title, "José — Directo")
        XCTAssertEqual(try XCTUnwrap(list.entries.last?.start), 1.013333, accuracy: 0.000001)
        XCTAssertEqual(try M3UPlaylist.decode(list.encoded(), utf8Only: true).entries, list.entries)
    }
    func testLocalFileUrisLegacyEncodingAndHashFilename() throws {
        let text = "#EXTM3U\n#EXTINF:0,Café\n./#track.mp3\nfile:///Music/Album%20One/02.flac\n"
        let list = try M3UPlaylist.decode(XCTUnwrap(text.data(using: .windowsCP1252)))
        XCTAssertEqual(list.entries.first?.title, "Café")
        XCTAssertEqual(list.entries.last?.path, "/Music/Album One/02.flac")
        XCTAssertEqual(try M3UPlaylist.decode(list.encoded()).entries, list.entries)
    }
    func testStreamsHaveExplicitProblemsAndHlsOrInvalidIntervalsAreRejected() throws {
        let list = try M3UPlaylist.decode(Data("https://example.com/stream.mp3\nreal.flac\n".utf8))
        XCTAssertEqual(list.entries.map(\.path), ["real.flac"])
        XCTAssertEqual(list.problems.count, 1)
        XCTAssertThrowsError(try M3UPlaylist.decode(Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\nchunk.aac".utf8)))
        XCTAssertThrowsError(try M3UPlaylist.decode(Data("#EXTVLCOPT:start-time=nan\nsong.flac".utf8)))
        XCTAssertThrowsError(try M3UPlaylist.decode(Data("#EXTVLCOPT:start-time=2\n#EXTVLCOPT:stop-time=1\nsong.flac".utf8)))
    }
    func testResolutionAllowsRelativeParentsOnlyInsideSelectedRoot() throws {
        let root = URL(fileURLWithPath: "/Music")
        let list = root.appendingPathComponent("Lists/road.m3u8")
        XCTAssertEqual(try M3UPlaylist.relativePath("../Album/song.flac", playlist: list, root: root), "Album/song.flac")
        XCTAssertThrowsError(try M3UPlaylist.relativePath("../../outside.flac", playlist: list, root: root))
        XCTAssertThrowsError(try M3UPlaylist.relativePath("/Other/song.flac", playlist: list, root: root))
    }
}
