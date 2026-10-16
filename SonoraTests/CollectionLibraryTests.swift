import SonoraCore
import XCTest
import SFBAudioEngine
@testable import Sonora

@MainActor
final class CollectionLibraryTests: XCTestCase {
    func testLocalFolderArtworkIsIndexedWithoutWritingEmbeddedTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        let coverFile = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac")))
        try XCTUnwrap(coverFile.metadata.attachedPictures.first?.imageData).write(to: root.appendingPathComponent("cover.png"))
        let songURL = root.appendingPathComponent("a.flac"); try FileManager.default.copyItem(at: fixture, to: songURL)
        let suite = "SonoraTests.SidecarIndex.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache")); defer { library.cancelIndexing() }
        try library.register(ScopedFolder(root), tracks: [AudioTrack(relativePath: "a.flac")!])
        let deadline = Date().addingTimeInterval(4)
        while library.isIndexing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let key = try XCTUnwrap(library.state.songs.values.first?.artworkKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.artworkDirectory.appendingPathComponent(key).path))
        XCTAssertTrue(try AudioFile(readingPropertiesAndMetadataFrom: songURL).metadata.attachedPictures.isEmpty)
    }
    func testAddingAnotherSourceDoesNotAbandonEarlierMetadataIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        let suite = "SonoraTests.IndexQueue.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache"))
        defer { library.cancelIndexing() }
        for name in ["First", "Second"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tracks = try (0..<16).map { value -> AudioTrack in
                let filename = "\(value).flac"
                try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent(filename))
                return AudioTrack(relativePath: filename)!
            }
            try library.register(ScopedFolder(folder), tracks: tracks)
        }
        let deadline = Date().addingTimeInterval(6)
        while library.isIndexing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(library.isIndexing); XCTAssertEqual(library.state.songs.count, 32)
        XCTAssertTrue(library.state.songs.values.allSatisfy { $0.tags[.title] == "Señal de prueba" }, "Every source must finish indexing, including the first")
    }
    func testUnfinishedLocalMetadataIndexResumesAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: root.appendingPathComponent("a.flac"))
        let suite = "SonoraTests.ResumeIndex.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache"))
        try library.register(ScopedFolder(root), tracks: [AudioTrack(relativePath: "a.flac")!])
        library.cancelIndexing()
        let restored = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache")); defer { restored.cancelIndexing() }
        let deadline = Date().addingTimeInterval(4)
        while restored.state.songs.values.first?.tags[.title] != "Señal de prueba" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.state.songs.values.first?.tags[.title], "Señal de prueba")
    }
    func testMetadataEditIsNotOverwrittenByPendingIndexResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))
        let tracks = try (0..<32).map { value -> AudioTrack in
            let name = String(format: "%02d.flac", value)
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name))
            return AudioTrack(relativePath: name)!
        }
        let suite = "SonoraTests.IndexEdit.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache")), folder = try ScopedFolder(root)
        let source = try library.register(folder, tracks: tracks)
        let snapshot = try await MetadataService.read(url: tracks[0].url(in: root), folder: folder)
        _ = try await MetadataService.save(url: tracks[0].url(in: root), folder: folder, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.title: "Edición más reciente"]))
        await library.refresh(track: tracks[0], source: source, folder: folder)
        let deadline = Date().addingTimeInterval(10)
        while library.isIndexing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(library.isIndexing)
        XCTAssertEqual(library.state.songs[source + "\0" + tracks[0].relativePath]?.title, "Edición más reciente")
    }

    func testLocalIndexAndUserCollectionPersistWithoutCopyingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: root.appendingPathComponent("a.flac"))
        let suite = "SonoraTests.Collection.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache"))
        let access = try ScopedFolder(root)
        let source = try library.register(access, tracks: [AudioTrack(relativePath: "a.flac")!])
        let deadline = Date().addingTimeInterval(6)
        while library.isIndexing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let song = try XCTUnwrap(library.state.songs.values.first)
        XCTAssertEqual(song.tags[.title], "Señal de prueba")
        XCTAssertEqual(song.sourceID, source)
        library.toggleFavorite(song.id)
        let playlist = try XCTUnwrap(library.createPlaylist("Prueba"))
        library.add([song.id], to: playlist)
        library.recordPlayed(song.id)
        let restored = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("cache"))
        XCTAssertEqual(restored.state, library.state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.flac").path))
        library.forgetSource(source)
        XCTAssertTrue(library.state.songs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.flac").path), "Forgetting a source must not delete audio")
    }
}
