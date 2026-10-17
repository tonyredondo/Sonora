import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class LinkMusicImportTests: XCTestCase {
    func testDownloadedAlbumBecomesPersistentSourceAndDecodesWithoutItsArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload.download"), storage = root.appendingPathComponent("Copies")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "transfer-import", withExtension: "zip")), to: payload)
        let record = try await LocalMusicImport.downloaded(payload, filename: "album.zip", name: "Álbum del enlace", linkID: "wetransfer:synthetic", storage: storage)
        XCTAssertEqual(record.files, 4)
        XCTAssertEqual(record.linkID, "wetransfer:synthetic")
        let music = LocalMusicImport.musicURL(record, storage: storage)
        XCTAssertEqual(try String(contentsOf: music.appendingPathComponent("Album/booklet.txt"), encoding: .utf8), "Companion file")
        let suite = "SonoraTests.LinkImport.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("Artwork"))
        defer { library.cancelIndexing() }
        let folder = try ScopedFolder(music), tracks = try await FolderScanService.scan(folder)
        let source = try library.register(folder, tracks: tracks, name: record.name)
        XCTAssertEqual(library.state.sources.count, 1)
        try FileManager.default.removeItem(at: payload)
        let again = try await LocalMusicImport.downloaded(payload, filename: "album.zip", name: "Duplicate", linkID: "wetransfer:synthetic", storage: storage)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(try LocalMusicImport.records(in: storage).count, 1)
        let restored = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("Artwork"))
        defer { restored.cancelIndexing() }
        let audio = try await MediaReader.prepare(XCTUnwrap(tracks.first), folder: restored.access(source))
        defer { try? audio.decoder.close() }
        XCTAssertEqual(audio.details.lyrics.lines.first?.text, "Prueba de enlace")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.decoder.processingFormat, frameCapacity: 1024))
        try audio.decoder.decode(into: buffer, length: buffer.frameCapacity)
        XCTAssertGreaterThan(buffer.frameLength, 0)
    }

    func testBadOrCancelledDownloadCannotPublishSourceDataAndKeepsExistingCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload.zip"), storage = root.appendingPathComponent("Copies")
        try Data("not a zip".utf8).write(to: payload)
        do { _ = try await LocalMusicImport.downloaded(payload, filename: "bad.zip", name: "Bad", linkID: "wetransfer:bad", storage: storage); XCTFail("Bad archive cannot publish") }
        catch { }
        XCTAssertTrue(try LocalMusicImport.records(in: storage).isEmpty)
        let work = Task { try await LocalMusicImport.downloaded(payload, filename: "bad.zip", name: "Cancelled", linkID: "wetransfer:cancelled", storage: storage) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled import cannot publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try LocalMusicImport.records(in: storage).isEmpty)
        XCTAssertEqual(try Data(contentsOf: payload), Data("not a zip".utf8))
    }
}
