import SonoraCore
import XCTest
@testable import Sonora

@MainActor
final class MultiFolderQueueTests: XCTestCase {
    func testAppendingSameFilenameFromAnotherFolderPreservesPauseAndRestoresBothSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] {
            let dir = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: dir.appendingPathComponent("same.flac"))
        }
        let suite = "SonoraTests.Multi.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root.appendingPathComponent("a"), autoPlay: false)
        player.seek(to: 0.1)
        let originalID = player.current?.id
        await player.appendFolder(root.appendingPathComponent("b"), playNext: true)
        XCTAssertEqual(player.queue.tracks.count, 2)
        XCTAssertEqual(player.current?.id, originalID)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.01)
        let ids = Set(player.queue.tracks.map(\.id)); XCTAssertEqual(ids.count, 2)
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.map(\.id), player.queue.tracks.map(\.id))
        XCTAssertEqual(restored.current?.id, originalID)
        XCTAssertEqual(restored.currentTime, 0.1, accuracy: 0.01)
        XCTAssertFalse(restored.isPlaying)
        restored.play(index: 1); restored.pause()
        let again = PlaybackController(defaults: defaults); defer { again.stop() }
        await again.restoreFolder()
        XCTAssertNotNil(again.current?.sourceID)
        XCTAssertEqual(again.current?.relativePath, "same.flac")
        XCTAssertFalse(again.isPlaying)
    }
}
