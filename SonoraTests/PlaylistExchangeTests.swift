import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class PlaylistExchangeTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("CD 2"), withIntermediateDirectories: true)
        for name in ["Café.flac", "CD 2/02.flac"] {
            try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: root.appendingPathComponent(name))
        }
        return root
    }
    func testImportReportsMissingEscapingAndRepeatedFilesAndPreservesValidOrder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Ruta.m3u8")
        try "#EXTM3U\nCD 2/02.flac\nmissing.mp3\n../outside.mp3\nCafé.flac\nCD 2/02.flac\nhttps://example.com/live.mp3\n".write(to: url, atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        let library = MusicLibrary(defaults: defaults)
        let report = try await PlaylistExchange.importPlaylist(PlaylistExchange.read(url), folder: root, library: library)
        let list = try XCTUnwrap(library.state.playlists.first { $0.id == report.playlistID })
        XCTAssertEqual(list.songIDs.compactMap { library.state.songs[$0]?.relativePath }, ["CD 2/02.flac", "Café.flac"])
        XCTAssertEqual(report.problems.count, 4)
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        player.playSongs(list.songIDs)
        let deadline = Date().addingTimeInterval(5)
        while player.currentDetails == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.queue.tracks.map(\.relativePath), ["CD 2/02.flac", "Café.flac"])
        XCTAssertNotNil(player.currentDetails); XCTAssertNil(player.issue)
        player.pause()
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.map(\.id), player.queue.tracks.map(\.id)); XCTAssertFalse(restored.isPlaying)
    }
    func testRelativeExportRoundTripsAndNeverOverwritesExistingList() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!)
        let tracks = try FolderScanner.scan(root), source = try library.register(ScopedFolder(root), tracks: tracks)
        let id = try XCTUnwrap(library.createPlaylist("Viaje"))
        library.add(tracks.reversed().map { $0.withSource(source).id }, to: id)
        let first = try await PlaylistExchange.exportPlaylist(id, library: library, folder: root, name: "Viaje", legacy: false)
        let original = try Data(contentsOf: first)
        let second = try await PlaylistExchange.exportPlaylist(id, library: library, folder: root, name: "Viaje", legacy: true)
        XCTAssertEqual(second.pathExtension, "m3u")
        _ = try await PlaylistExchange.exportPlaylist(id, library: library, folder: root, name: "Viaje", legacy: false)
        XCTAssertEqual(try Data(contentsOf: first), original)
        let content = try String(contentsOf: first, encoding: .utf8)
        XCTAssertFalse(content.contains(root.path)); XCTAssertTrue(content.contains("CD 2/02.flac"))
        let result = try await PlaylistExchange.importPlaylist(PlaylistExchange.read(first), folder: root, library: library)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(library.state.playlists.first { $0.id == result.playlistID }?.songIDs, library.state.playlists.first { $0.id == id }?.songIDs)
    }
    func testNoResolvableSongsLeavesLibraryUnchanged() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bad.m3u"); try "missing.mp3".write(to: url, atomically: true, encoding: .utf8)
        let library = MusicLibrary(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!)
        do { _ = try await PlaylistExchange.importPlaylist(PlaylistExchange.read(url), folder: root, library: library); XCTFail("Expected an explicit error") } catch { }
        XCTAssertTrue(library.state.playlists.isEmpty); XCTAssertTrue(library.state.sources.isEmpty)
    }
    func testCuePlaylistExportAndImportRetainsIndividualIntervalsAndOrder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try "FILE \"Café.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"Inicio\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Final\"\nINDEX 01 00:00:10\n".write(to: root.appendingPathComponent("Disk.cue"), atomically: true, encoding: .utf8)
        let library = MusicLibrary(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!)
        let tracks = try FolderScanner.scan(root), source = try library.register(ScopedFolder(root), tracks: tracks)
        let virtual = tracks.filter { $0.cue != nil }.reversed().map { $0.withSource(source).id }
        let id = try XCTUnwrap(library.createPlaylist("CUE portátil")); library.add(virtual, to: id)
        let url = try await PlaylistExchange.exportPlaylist(id, library: library, folder: root, name: "CUE portátil", legacy: false)
        let report = try await PlaylistExchange.importPlaylist(PlaylistExchange.read(url), folder: root, library: library)
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(library.state.playlists.first { $0.id == report.playlistID }?.songIDs, virtual)
    }
}
