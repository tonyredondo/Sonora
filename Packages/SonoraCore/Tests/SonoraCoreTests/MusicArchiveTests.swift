import Foundation
import XCTest
import ZIPFoundation
@testable import SonoraCore

final class MusicArchiveTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func archive(_ url: URL, entries: [(String, Data, Entry.EntryType)]) throws {
        let zip = try Archive(url: url, accessMode: .create)
        for (name, data, type) in entries {
            try zip.addEntry(with: name, type: type, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
    }
    func testExtractsNestedAlbumsAndCompanionFilesWithoutKeepingPackagingArchives() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("album.zip")
        try archive(inner, entries: [("CD 2/song.flac", Data("audio".utf8), .file), ("CD 2/song.lrc", Data("lyrics".utf8), .file), ("booklet.pdf", Data("notes".utf8), .file)])
        let outer = root.appendingPathComponent("transfer.zip"), destination = root.appendingPathComponent("Music")
        try archive(outer, entries: [("Album.zip", try Data(contentsOf: inner), .file), ("cover.jpg", Data("cover".utf8), .file)])
        let result = try MusicArchive.extract(outer, to: destination)
        XCTAssertEqual(result.files, 4)
        XCTAssertEqual(result.bytes, 21)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Album/CD 2/song.flac")), Data("audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Album/CD 2/song.lrc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Album/booklet.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Album.zip").path))
    }
    func testRejectsTraversalSymlinksAndDuplicateDestinations() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, entries) in [
            [("../escape.mp3", Data("bad".utf8), Entry.EntryType.file)],
            [("escape", Data("../../outside".utf8), Entry.EntryType.symlink)],
            [("song.mp3", Data([1]), Entry.EntryType.file), ("song.mp3", Data([2]), Entry.EntryType.file)]
        ].enumerated() {
            let zip = root.appendingPathComponent("\(index).zip")
            try archive(zip, entries: entries)
            XCTAssertThrowsError(try MusicArchive.extract(zip, to: root.appendingPathComponent("Result-\(index)")))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.mp3").path))
    }
    func testCancellationCorruptionAndExpansionBudgetStopExtraction() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("transfer.zip")
        try archive(zip, entries: [("song.wav", Data(repeating: 7, count: 200_000), .file)])
        XCTAssertThrowsError(try MusicArchive.extract(zip, to: root.appendingPathComponent("Small"), maxBytes: 10))
        var cancelled = false
        XCTAssertThrowsError(try MusicArchive.extract(zip, to: root.appendingPathComponent("Cancelled"), isCancelled: { cancelled }) { value in
            if value.bytes > 0 { cancelled = true }
        }) { XCTAssertTrue($0 is CancellationError) }
        var broken = try Data(contentsOf: zip)
        // A stored entry's payload starts after its 30-byte local header and filename.
        broken[30 + "song.wav".utf8.count] ^= 0xff
        let corrupt = root.appendingPathComponent("corrupt.zip"); try broken.write(to: corrupt)
        XCTAssertThrowsError(try MusicArchive.extract(corrupt, to: root.appendingPathComponent("Corrupt")))
    }
}
