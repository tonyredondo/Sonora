import Foundation
import XCTest
@testable import SonoraCore

final class FolderScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testRecursesAndSortsNumericallyWithoutMergingDuplicateNames() throws {
        for path in ["CD 10/01.flac", "CD 2/10.mp3", "CD 2/02.mp3", "CD 1/02.mp3", "cover.jpg", "notes.txt"] {
            try file(path)
        }
        let tracks = try FolderScanner.scan(root)
        XCTAssertEqual(tracks.map(\.relativePath), ["CD 1/02.mp3", "CD 2/02.mp3", "CD 2/10.mp3", "CD 10/01.flac"])
        XCTAssertEqual(Set(tracks.map(\.id)).count, 4)
    }

    func testNeverFollowsSymbolicLinksOutsideFolder() throws {
        try file("real.wav")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside.appendingPathComponent("outside.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        XCTAssertEqual(try FolderScanner.scan(root).map(\.relativePath), ["real.wav"])
    }

    func testCancellationAndMissingFolderAreErrors() throws {
        try file("01.WAV")
        XCTAssertThrowsError(try FolderScanner.scan(root, isCancelled: { true }))
        XCTAssertThrowsError(try FolderScanner.scan(root.appendingPathComponent("missing")))
    }
    func testDanglingSiblingLinkDoesNotHideNestedRegularAudio() throws {
        try file("CD 2/song.flac")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.flac"), withDestinationURL: root.appendingPathComponent("missing.flac"))
        XCTAssertEqual(try FolderScanner.scan(root).map(\.relativePath), ["CD 2/song.flac"])
    }

    func testRestoredPathsCannotEscapeAuthorizedRoot() {
        XCTAssertNil(AudioTrack(relativePath: "../outside.mp3"))
        XCTAssertNil(AudioTrack(relativePath: "/tmp/outside.mp3"))
        XCTAssertNil(AudioTrack(relativePath: "CD/../../outside.mp3"))
        XCTAssertNotNil(AudioTrack(relativePath: "CD 1/01.mp3"))
    }
}
