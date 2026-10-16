import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class LocalMusicImportTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Source/CD 2"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: root.appendingPathComponent("Source/CD 2/song.flac"))
        try "[00:00]Letra".write(to: root.appendingPathComponent("Source/CD 2/song.lrc"), atomically: true, encoding: .utf8)
        return root
    }
    func testCopyPreservesNestedAudioAndLyricsAndPlaysAfterOriginalIsRemoved() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Copies")
        let copied = try await LocalMusicImport.copy(source, storage: storage)
        let audio = LocalMusicImport.musicURL(copied, storage: storage).appendingPathComponent("CD 2/song.flac")
        XCTAssertEqual(try Data(contentsOf: audio), try Data(contentsOf: source.appendingPathComponent("CD 2/song.flac")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension("lrc").path))
        XCTAssertEqual(try LocalMusicImport.records(in: storage).map(\.id), [copied.id])
        try FileManager.default.removeItem(at: source)
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(LocalMusicImport.musicURL(copied, storage: storage), autoPlay: false, name: "Source · Local")
        XCTAssertEqual(player.queue.tracks.count, 1); XCTAssertEqual(player.currentDetails?.lyrics.lines.first?.text, "Letra")
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder(); XCTAssertEqual(restored.queue.tracks.count, 1)
        XCTAssertEqual(restored.folderName, "Source · Local")
        XCTAssertNil(restored.issue); XCTAssertFalse(restored.isPlaying)
    }
    func testEmptyFolderDoesNotPublishAnyCopy() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty"), storage = root.appendingPathComponent("Copies")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do { _ = try await LocalMusicImport.copy(empty, storage: storage); XCTFail("Expected no-audio error") } catch { }
        XCTAssertTrue(try LocalMusicImport.records(in: storage).isEmpty)
    }
    func testDestinationFailurePreservesOriginalsAndExistingDestination() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), blocked = root.appendingPathComponent("Blocked")
        let original = try Data(contentsOf: source.appendingPathComponent("CD 2/song.flac")), marker = Data("Keep existing file".utf8)
        try marker.write(to: blocked)
        do { _ = try await LocalMusicImport.copy(source, storage: blocked); XCTFail("Expected a destination error") } catch { }
        XCTAssertEqual(try Data(contentsOf: blocked), marker)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("CD 2/song.flac")), original)
    }
    func testCancellationAndEmptyImportLeaveNoPublishedCopyAndNeverFollowSymlinks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Copies")
        let work = Task { try await LocalMusicImport.copy(source, storage: storage) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(try LocalMusicImport.records(in: storage).isEmpty)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape.flac"), withDestinationURL: root.appendingPathComponent("outside.flac"))
        let copied = try await LocalMusicImport.copy(source, storage: storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalMusicImport.musicURL(copied, storage: storage).appendingPathComponent("escape.flac").path))
        let before = try Data(contentsOf: source.appendingPathComponent("CD 2/song.flac"))
        try LocalMusicImport.remove(copied, storage: storage)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("CD 2/song.flac")), before)
        XCTAssertTrue(try LocalMusicImport.records(in: storage).isEmpty)
    }
}
