import Foundation
import XCTest
@testable import SonoraCore

final class CueSheetTests: XCTestCase {
    private func folder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testScanReplacesAlbumImageWithNamedDistinctVirtualTracksAndRoundTrips() throws {
        try folder { root in
            try Data().write(to: root.appendingPathComponent("Live.flac"))
            try """
            PERFORMER "The Band"
            TITLE "Live in Madrid"
            FILE "Live.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Arrival"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Finale"
                INDEX 00 00:00:65
                INDEX 01 00:01:00
            """.write(to: root.appendingPathComponent("Live.cue"), atomically: true, encoding: .utf8)
            let tracks = try FolderScanner.scan(root)
            XCTAssertEqual(tracks.count, 2)
            XCTAssertEqual(tracks.map(\.displayName), ["Arrival", "Finale"])
            XCTAssertEqual(Set(tracks.map(\.id)).count, 2)
            XCTAssertEqual(tracks.map(\.relativePath), ["Live.flac", "Live.flac"])
            XCTAssertEqual(try JSONDecoder().decode([AudioTrack].self, from: JSONEncoder().encode(tracks)), tracks)
        }
    }
    func testMultiFileCueKeepsDiscOrderAndAcceptsWindowsSeparatorsAndLegacyText() throws {
        try folder { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("CD"), withIntermediateDirectories: true)
            for name in ["CD/z.wav", "CD/a.wav"] { try Data().write(to: root.appendingPathComponent(name)) }
            let text = "PERFORMER \"José\"\nTITLE \"Directo\"\nFILE \"CD\\z.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"Primero\"\nINDEX 01 00:00:00\nFILE \"CD\\a.wav\" WAVE\nTRACK 02 AUDIO\nTITLE \"Último\"\nINDEX 01 00:00:00\n"
            try XCTUnwrap(text.data(using: .windowsCP1252)).write(to: root.appendingPathComponent("Disc.cue"))
            XCTAssertEqual(try FolderScanner.scan(root).map(\.displayName), ["Primero", "Último"])
        }
    }
    func testInvalidBoundariesMissingFilesAndEscapingPathsAreExplicitErrors() throws {
        for content in [
            "FILE \"../outside.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00",
            "FILE \"missing.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00",
            "FILE \"song.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:02:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00",
            "FILE \"song.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:75"
        ] {
            try folder { root in
                try Data().write(to: root.appendingPathComponent("song.wav"))
                try content.write(to: root.appendingPathComponent("bad.cue"), atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try FolderScanner.scan(root))
            }
        }
    }
    func testCueReferencesCanUseRelativeParentsInsideTheAuthorizedFolder() throws {
        try folder { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sheets"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("Audio.flac"))
            try "FILE \".././Audio.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00".write(to: root.appendingPathComponent("Sheets/Disc.cue"), atomically: true, encoding: .utf8)
            XCTAssertEqual(try FolderScanner.scan(root).map(\.relativePath), ["Audio.flac"])
        }
    }
    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock(); private var value = false
        var cancelled: Bool { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
    }
    func testCancellationAfterReadingCueDoesNotPublishAResult() throws {
        try folder { root in
            try Data().write(to: root.appendingPathComponent("Audio.flac"))
            let data = Data("FILE \"Audio.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00".utf8)
            try data.write(to: root.appendingPathComponent("Disc.cue"))
            let cancellation = Cancellation()
            XCTAssertThrowsError(try FolderScanner.scan(root, isCancelled: { cancellation.cancelled }, readText: { _ in
                cancellation.cancelled = true; return data
            })) { XCTAssertTrue($0 is CancellationError) }
        }
    }
}
