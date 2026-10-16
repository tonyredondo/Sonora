import Foundation
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class VolumeSessionTests: XCTestCase {
    private func withPlayer(_ body: (PlaybackController, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "volume", withExtension: "wav"))
        for name in ["a.wav", "b.wav"] { try FileManager.default.copyItem(at: original, to: root.appendingPathComponent(name)) }
        let suite = "SonoraTests.VolumeSession.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        try await body(player, root)
    }
    private func wait(_ session: VolumeAnalysisSession) async throws {
        let deadline = Date().addingTimeInterval(8)
        while session.isWorking && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.isWorking)
    }
    func testReusesFreshTracksAndReanalyzesOnlyTheChangedFile() async throws {
        try await withPlayer { player, root in
            let session = VolumeAnalysisSession(player: player, selection: .init(tracks: player.queue.tracks))
            await session.load(); session.start(); try await wait(session)
            XCTAssertEqual(session.analyzedCount, 2); XCTAssertEqual(session.reusedCount, 0)
            session.start(); try await wait(session)
            XCTAssertEqual(session.analyzedCount, 0); XCTAssertEqual(session.reusedCount, 2)
            let target = try XCTUnwrap(session.targets.first)
            _ = try await MetadataService.save(url: target.url, folder: target.folder, expected: FileFingerprint(target.url), patch: .init(values: [.title: "Edición externa"]))
            session.start(); try await wait(session)
            XCTAssertEqual(session.analyzedCount, 1); XCTAssertEqual(session.reusedCount, 1)
            XCTAssertEqual(session.status, "Análisis completado")
            XCTAssertTrue(session.failures.isEmpty)
        }
    }
    func testAlbumAnalysisAndTagSaveKeepTheWholeAlbumCacheValid() async throws {
        try await withPlayer { player, _ in
            let session = VolumeAnalysisSession(player: player, selection: .init(tracks: player.queue.tracks, album: true))
            await session.load(); session.start(); try await wait(session)
            XCTAssertEqual(session.analyzedCount, 2); XCTAssertNotNil(session.albumResult)
            session.start(); try await wait(session)
            XCTAssertEqual(session.reusedCount, 2); XCTAssertEqual(session.analyzedCount, 0)
            session.saveTags(); try await wait(session)
            XCTAssertEqual(session.saveResult?.written, 2); XCTAssertTrue(session.saveResult?.failures.isEmpty == true)
            for target in session.targets {
                let candidate = try XCTUnwrap(player.volumeAnalysis.candidate(for: target.id, members: session.targets))
                XCTAssertNotNil(candidate.validated(fingerprint: try FileFingerprint(target.url))?.albumGain)
            }
            XCTAssertFalse(player.isPlaying)
        }
    }
    func testSelectionReportsOneBadFileAndImmediateCancellationDoesNotReplaceResults() async throws {
        try await withPlayer { player, root in
            try Data("broken audio".utf8).write(to: root.appendingPathComponent("bad.flac"))
            await player.loadFolder(root, autoPlay: false)
            let session = VolumeAnalysisSession(player: player, selection: .init(tracks: player.queue.tracks))
            await session.load(); session.start(); try await wait(session)
            XCTAssertEqual(session.analyzedCount, 2); XCTAssertEqual(session.failures.count, 1)
            XCTAssertEqual(session.status, "Análisis con incidencias")
            let saved = player.volumeAnalysis.records
            session.start(force: true); session.cancel(); try await wait(session)
            XCTAssertEqual(player.volumeAnalysis.records, saved)
            XCTAssertEqual(session.status, "Análisis cancelado")
        }
    }
    func testAddingAnAlbumMemberInvalidatesTheOldAlbumGainDuringPlayback() async throws {
        try await withPlayer { player, root in
            let targets = try player.volumeTargets(for: player.queue.tracks)
            try player.volumeAnalysis.record(try await VolumeAnalysisService.analyze(targets, album: true))
            try FileManager.default.copyItem(at: root.appendingPathComponent("a.wav"), to: root.appendingPathComponent("c.wav"))
            await player.loadFolder(root, autoPlay: false)
            let track = try XCTUnwrap(player.current), folder = try player.folderAccess(for: track)
            let candidate = try XCTUnwrap(player.volumeCandidate(for: track, folder: folder, includeAlbum: true))
            let value = try await VolumeAnalysisService.cachedGain(candidate, url: track.url(in: folder.url))
            XCTAssertNotNil(value?.trackGain); XCTAssertNil(value?.albumGain)
        }
    }
    func testForgettingASourceCannotBeUndoneByAQueuedAnalysisResult() async throws {
        for album in [false, true] {
            try await withPlayer { player, _ in
                let session = VolumeAnalysisSession(player: player, selection: .init(tracks: player.queue.tracks, album: album))
                await session.load(); session.start()
                player.forgetSource(try XCTUnwrap(player.library.state.sources.first?.id))
                try await wait(session)
                XCTAssertTrue(player.volumeAnalysis.records.isEmpty, "A late analysis must not recreate forgotten source references")
                XCTAssertNotEqual(session.status, "Análisis completado")
            }
        }
    }
}
