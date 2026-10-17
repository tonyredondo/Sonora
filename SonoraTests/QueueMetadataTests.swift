import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor
final class QueueMetadataTests: XCTestCase {
    func testPreparedCurrentMetadataRemainsVisibleWhileLibraryIndexIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        let url = root.appendingPathComponent("filename.flac")
        try FileManager.default.copyItem(at: fixture, to: url)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.title = "Información ya preparada"; file.metadata.artist = "Artista inmediato"; try file.writeMetadata()
        let suite = "SonoraTests.QueuePending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        player.library.cancelIndexing()
        let track = try XCTUnwrap(player.current)
        let id = try XCTUnwrap(player.libraryID(for: track))
        XCTAssertNil(player.library.state.songs[id]?.modified, "Exercise the placeholder before background indexing completes")
        XCTAssertEqual(player.details[track.id]?.title, "Información ya preparada")
        XCTAssertEqual(TrackRow(player: player, track: track).title, "Información ya preparada")
        XCTAssertEqual(TrackRow(player: player, track: track).subtitle, "Artista inmediato")
    }

    func testBatchRowsUseSavedMetadataBeyondPlaybackCacheAndAfterRestoration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        for index in 0..<20 {
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(String(format: "%02d.flac", index)))
        }
        let suite = "SonoraTests.QueueBatch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false, name: "Biblioteca")
        let tracks = player.queue.tracks
        XCTAssertEqual(tracks.count, 20)
        let selected = player.current?.id
        var expected: [String: FileFingerprint] = [:]
        for track in tracks { expected[track.id] = try await player.readMetadata(for: track).fingerprint }
        let result = await player.saveMetadataBatch(tracks, expected: expected,
            patch: MetadataPatch(values: [.artist: "Artista por lotes", .album: "Nuevo álbum"]), progress: { _ in })
        XCTAssertEqual(result.written, 20); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(player.current?.id, selected); XCTAssertFalse(player.isPlaying)
        XCTAssertLessThanOrEqual(player.details.count, 16, "Displaying all metadata must not grow the playback cache")
        for track in tracks {
            let row = TrackRow(player: player, track: track)
            XCTAssertEqual(row.title, "Señal de prueba", track.id)
            XCTAssertEqual(row.subtitle, "Artista por lotes", track.id)
        }
        let restored = PlaybackController(defaults: defaults)
        defer { restored.stop(); restored.library.cancelIndexing() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.count, 20); XCTAssertFalse(restored.isPlaying)
        for track in restored.queue.tracks {
            XCTAssertEqual(TrackRow(player: restored, track: track).subtitle, "Artista por lotes", track.id)
        }
    }

    func testSingleEditResolvesSourceIdentityAndReflectsClearedArtistAndArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        for (folder, title, artist) in [(first, "Primera canción", "Primer artista"), (second, "Segunda canción", "Segundo artista")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("same.flac")
            try FileManager.default.copyItem(at: fixture, to: url)
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            file.metadata.title = title; file.metadata.artist = artist; try file.writeMetadata()
        }
        let suite = "SonoraTests.QueueSources.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(first, autoPlay: false)
        let primary = try XCTUnwrap(player.current)
        let localTrack = try XCTUnwrap(AudioTrack(relativePath: "same.flac"))
        let source = try player.library.register(ScopedFolder(second), tracks: [localTrack])
        let other = localTrack.withSource(source)
        player.enqueueSongs([other.id], playNext: false)
        XCTAssertTrue(player.queue.tracks.contains(other))
        let coverFile = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac")))
        let cover = try XCTUnwrap(coverFile.metadata.attachedPictures.first?.imageData)
        let before = try await player.readMetadata(for: other)
        try await player.saveMetadata(for: other, expected: before.fingerprint,
            patch: MetadataPatch(values: [.title: "Solo segunda carpeta", .artist: ""], artwork: .replace(cover)))
        XCTAssertEqual(TrackRow(player: player, track: primary).title, "Primera canción")
        XCTAssertEqual(TrackRow(player: player, track: primary).subtitle, "Primer artista")
        XCTAssertEqual(TrackRow(player: player, track: other).title, "Solo segunda carpeta")
        XCTAssertEqual(TrackRow(player: player, track: other).subtitle, "Artista desconocido")
        XCTAssertEqual(TrackRow(player: player, track: other, showsLocation: true).subtitle, "Second/same.flac")
        let indexed = try XCTUnwrap(player.library.state.songs[other.id])
        let key = try XCTUnwrap(indexed.artworkKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: player.library.artworkDirectory.appendingPathComponent(key).path))
        let updated = try await player.readMetadata(for: other)
        try await player.saveMetadata(for: other, expected: updated.fingerprint, patch: MetadataPatch(artwork: .remove))
        XCTAssertNil(player.library.state.songs[other.id]?.artworkKey)
        XCTAssertEqual(TrackRow(player: player, track: other).title, "Solo segunda carpeta")
        XCTAssertFalse(player.isPlaying)
    }
}
