import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class SourceFileDeletionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SonoraDeletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func audio(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: url)
    }
    private func player(storage: URL) throws -> (PlaybackController, UserDefaults, String) {
        let suite = "SonoraTests.Delete." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PlaybackController(defaults: defaults, localStorage: storage), defaults, suite)
    }
    private func item(_ path: String, in folder: ScopedFolder) async throws -> SourceFile {
        let parent = (path as NSString).deletingLastPathComponent
        let items = try await SourceFileService.contents(in: folder, path: parent)
        return try XCTUnwrap(items.first { $0.relativePath == path })
    }
    private func settle(_ player: PlaybackController) async throws {
        let deadline = Date().addingTimeInterval(8)
        while (player.library.isIndexing || player.isPreparing) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(player.library.isIndexing); XCTAssertFalse(player.isPreparing)
    }

    func testBrowserAndDeletionStayInsideSourceAndRejectChangedItems() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), outside = root.appendingPathComponent("outside.flac")
        try audio(source.appendingPathComponent("Album/song.flac")); try audio(outside)
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        let folder = try ScopedFolder(source)
        let rows = try await SourceFileService.contents(in: folder)
        XCTAssertEqual(rows.map(\.name), ["Album", "notes.txt"])
        let song = try await item("Album/song.flac", in: folder)
        try Data("replacement".utf8).write(to: source.appendingPathComponent(song.relativePath), options: .atomic)
        do { try await SourceFileService.remove(song, from: folder); XCTFail("A changed item must be reviewed again") } catch { }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(song.relativePath)), Data("replacement".utf8))
        for path in ["../outside.flac", "/outside.flac", "Album/../notes.txt", "escape"] {
            do { _ = try await SourceFileService.contents(in: folder, path: path); XCTFail("Unsafe path: " + path) } catch { }
        }
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Album/inside-link"), withDestinationURL: root)
        try await SourceFileService.remove(try await item("Album", in: folder), from: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Recursive removal must remove links, never their destinations")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("notes.txt"), encoding: .utf8), "notes")
    }

    func testDeletingFolderReconcilesCueTracksOverlappingSourcesAndPersistedReferences() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source"), album = sourceURL.appendingPathComponent("Album")
        try audio(album.appendingPathComponent("live.flac")); try audio(sourceURL.appendingPathComponent("Album extra/keep.flac"))
        try """
        FILE "live.flac" WAVE
        TRACK 01 AUDIO
        INDEX 01 00:00:00
        TRACK 02 AUDIO
        INDEX 01 00:00:10
        """.write(to: album.appendingPathComponent("live.cue"), atomically: true, encoding: .utf8)
        let (player, defaults, suite) = try player(storage: root.appendingPathComponent("Copies"))
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        await player.loadFolder(sourceURL, autoPlay: false)
        let primary = try XCTUnwrap(player.library.state.sources.first?.id)
        let nested = try player.library.register(ScopedFolder(album), tracks: FolderScanner.scan(album))
        player.enqueueSongs(player.library.state.songs.values.filter { $0.sourceID == nested }.map(\.id), playNext: false)
        let removed = Set(player.library.state.songs.values.filter { $0.relativePath.hasPrefix("Album/") || $0.sourceID == nested }.map(\.id))
        XCTAssertEqual(removed.count, 4)
        let keep = try XCTUnwrap(player.library.state.songs.values.first { $0.relativePath == "Album extra/keep.flac" })
        let playlist = try XCTUnwrap(player.library.createPlaylist("Keep surviving songs"))
        let all = Array(player.library.state.songs.keys)
        player.library.add(all, to: playlist)
        for id in all { player.library.toggleFavorite(id); player.library.recordPlayed(id) }
        try await player.deleteSourceFile(try await item("Album", in: player.library.access(primary)), sourceID: primary)
        try await settle(player)
        XCTAssertEqual(Set(player.library.state.songs.keys), [keep.id])
        XCTAssertEqual(player.library.state.favorites, [keep.id])
        XCTAssertEqual(player.library.state.playlists.first?.songIDs, [keep.id])
        XCTAssertEqual(player.library.state.history.map(\.songID), [keep.id])
        XCTAssertFalse(player.library.state.sources.contains { $0.id == nested })
        XCTAssertEqual(player.queue.tracks.map(\.relativePath), ["Album extra/keep.flac"])
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        let restored = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("Copies"))
        defer { restored.stop(); restored.library.cancelIndexing() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.library.state.songs.count, 1)
        XCTAssertEqual(restored.queue.tracks.map(\.relativePath), ["Album extra/keep.flac"])
    }

    func testFailedDeletionKeepsQueueLibraryAndBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"); try audio(source.appendingPathComponent("song.flac"))
        let (player, defaults, suite) = try player(storage: root.appendingPathComponent("Copies"))
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        await player.loadFolder(source, autoPlay: false)
        let id = try XCTUnwrap(player.library.state.sources.first?.id)
        let stale = try await item("song.flac", in: player.library.access(id))
        let songURL = source.appendingPathComponent("song.flac"), bytes = try Data(contentsOf: songURL)
        try bytes.write(to: songURL, options: .atomic)
        let queue = player.queue.tracks
        do { try await player.deleteSourceFile(stale, sourceID: id); XCTFail("Expected stale-item error") } catch { }
        try await settle(player)
        XCTAssertEqual(player.queue.tracks, queue)
        XCTAssertEqual(player.library.state.songs.count, 1)
        XCTAssertEqual(try Data(contentsOf: songURL), bytes)
        XCTAssertFalse(player.isPlaying)
    }

    func testDeletingCueSheetRetainsAudioAsWholeTrackWithoutResurrectingSegments() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"); try audio(source.appendingPathComponent("live.flac"))
        try "FILE \"live.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n".write(to: source.appendingPathComponent("live.cue"), atomically: true, encoding: .utf8)
        let (player, defaults, suite) = try player(storage: root.appendingPathComponent("Copies"))
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        await player.loadFolder(source, autoPlay: false)
        let id = try XCTUnwrap(player.library.state.sources.first?.id)
        XCTAssertNotNil(player.current?.cue)
        do {
            try await player.deleteSourceFile(try await item("live.flac", in: player.library.access(id)), sourceID: id)
            XCTFail("Keep the source valid: remove its CUE first or delete the complete folder")
        } catch { XCTAssertTrue(error.localizedDescription.contains("CUE")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("live.flac").path))
        XCTAssertNotNil(player.current?.cue)
        try await player.deleteSourceFile(try await item("live.cue", in: player.library.access(id)), sourceID: id)
        try await settle(player)
        XCTAssertTrue(player.queue.tracks.isEmpty)
        let song = try XCTUnwrap(player.library.state.songs.values.first)
        XCTAssertEqual(player.library.state.songs.count, 1); XCTAssertNil(song.cue)
        let prepared = try await MediaReader.prepare(XCTUnwrap(song.audioTrack), folder: player.library.access(id))
        defer { try? prepared.decoder.close() }
        XCTAssertGreaterThan(prepared.decoder.length, 0)
    }

    func testDeletingPlayingFileResumesSurvivorAndClearsEndOfTrackTimer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<44100 { buffer.floatChannelData![channel][frame] = 0.001 } }
        for name in ["a.wav", "b.wav"] {
            let file = try AVAudioFile(forWriting: source.appendingPathComponent(name), settings: format.settings)
            for _ in 0..<8 { try file.write(from: buffer) }
        }
        let (player, defaults, suite) = try player(storage: root.appendingPathComponent("Copies"))
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        player.setTransition(mode: .crossfade, duration: 1)
        await player.loadFolder(source)
        let deadline = Date().addingTimeInterval(4)
        while !player.isPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isPlaying)
        player.setSleepTimer(.endOfTrack(try XCTUnwrap(player.current?.id)))
        let id = try XCTUnwrap(player.library.state.sources.first?.id)
        try await player.deleteSourceFile(try await item("a.wav", in: player.library.access(id)), sourceID: id)
        try await settle(player)
        XCTAssertEqual(player.current?.relativePath, "b.wav")
        XCTAssertEqual(player.queue.tracks.map(\.relativePath), ["b.wav"])
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.sleepTimer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.wav").path))
    }

    func testDownloadedFileDeletionUpdatesSizeAndEmptyCopyCanBeImportedAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("original.flac"), storage = root.appendingPathComponent("Copies")
        try audio(payload)
        let bytes = try Data(contentsOf: payload)
        let record = try await LocalMusicImport.downloaded(payload, filename: "song.flac", name: "Download QA", linkID: "wetransfer:delete-fixture", storage: storage)
        let (player, defaults, suite) = try player(storage: storage)
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        try await player.localImports.include(record, library: player.library)
        let source = try XCTUnwrap(player.library.state.sources.first?.id)
        player.enqueueSongs(Array(player.library.state.songs.keys), playNext: false)
        try await player.deleteSourceFile(try await item("song.flac", in: player.library.access(source)), sourceID: source)
        let updated = try XCTUnwrap(player.localImports.copies.first)
        XCTAssertEqual(updated.files, 0); XCTAssertEqual(updated.bytes, 0)
        XCTAssertNil(updated.linkID, "An empty download must not prevent importing its link again")
        XCTAssertEqual(try LocalMusicImport.records(in: storage), [updated])
        XCTAssertTrue(player.library.state.songs.isEmpty); XCTAssertTrue(player.queue.tracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
        let again = try await LocalMusicImport.downloaded(payload, filename: "song.flac", name: "Download QA", linkID: "wetransfer:delete-fixture", storage: storage)
        XCTAssertNotEqual(again.id, record.id)
        try await player.deleteLocalCopy(updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalMusicImport.musicURL(updated, storage: storage).path))
        XCTAssertFalse(player.library.state.sources.contains { $0.id == source })
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalMusicImport.musicURL(again, storage: storage).appendingPathComponent("song.flac").path))
    }
    func testDeletingFolderContainingCurrentAndEarlierTracksSelectsImmediateSurvivor() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        for path in ["Gone/01.flac", "Gone/02.flac", "Keep/01.flac", "Keep/02.flac", "Keep/03.flac"] { try audio(source.appendingPathComponent(path)) }
        let (player, defaults, suite) = try player(storage: root.appendingPathComponent("Copies"))
        defer { player.stop(); player.library.cancelIndexing(); defaults.removePersistentDomain(forName: suite) }
        await player.loadFolder(source, autoPlay: false)
        let id = try XCTUnwrap(player.library.state.sources.first?.id)
        player.play(index: 1); player.pause()
        try await settle(player)
        XCTAssertEqual(player.current?.relativePath, "Gone/02.flac")
        try await player.deleteSourceFile(try await item("Gone", in: player.library.access(id)), sourceID: id)
        try await settle(player)
        XCTAssertEqual(player.current?.relativePath, "Keep/01.flac")
        XCTAssertFalse(player.isPlaying)
    }

}
