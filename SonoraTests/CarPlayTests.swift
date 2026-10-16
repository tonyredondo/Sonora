import CarPlay
import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class CarPlayTests: XCTestCase {
    private func player() async throws -> (PlaybackController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<88200 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.05) } }
        try AVAudioFile(forWriting: root.appendingPathComponent("song.wav"), settings: format.settings).write(from: buffer)
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!)
        await player.loadFolder(root, autoPlay: false)
        return (player, root)
    }
    func testRealTemplatesExposeLibraryPlaylistsFavoritesAndQueueWithWorkingSelection() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        XCTAssertEqual(car.rootTemplate.templates.map(\.tabTitle), ["Biblioteca", "Playlists", "Favoritos", "Cola"])
        let queue = try XCTUnwrap(car.rootTemplate.templates.last as? CPListTemplate)
        let row = try XCTUnwrap(queue.sections.first?.items.first as? CPListItem)
        var completed = false
        row.handler?(row, { completed = true })
        XCTAssertTrue(completed)
        XCTAssertTrue(shown.last === CPNowPlayingTemplate.shared)
        let deadline = Date().addingTimeInterval(3)
        while !player.isPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isPlaying); XCTAssertEqual(player.current?.relativePath, "song.wav")
    }
    func testRootUpdatesAfterFavoriteAndPlaylistChangesAndDisconnectStopsObservation() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        car.start()
        defer { car.stop() }
        let list = try XCTUnwrap(player.library.createPlaylist("Carretera"))
        let song = try XCTUnwrap(player.library.state.songs.keys.first)
        player.library.add([song], to: list); player.library.toggleFavorite(song)
        try await Task.sleep(for: .milliseconds(300))
        let playlists = try XCTUnwrap(car.rootTemplate.templates[1] as? CPListTemplate)
        XCTAssertEqual((playlists.sections.first?.items.first as? CPListItem)?.text, "Carretera")
        let favorites = try XCTUnwrap(car.rootTemplate.templates[2] as? CPListTemplate)
        XCTAssertFalse(favorites.sections.isEmpty)
        car.stop()
        _ = player.library.createPlaylist("Tras desconectar")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playlists.sections.first?.items.count, 1)
        car.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playlists.sections.first?.items.count, 2)
    }
    func testPaginationKeepsEveryPlaylistWithoutGrowingTheNavigationStack() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let names = (0..<205).map { "Lista \($0)" }
        for name in names { _ = player.library.createPlaylist(name) }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        let list = try XCTUnwrap(car.rootTemplate.templates[1] as? CPListTemplate)
        var observed: [String] = []
        for _ in 0..<4 {
            let items = list.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
            XCTAssertLessThanOrEqual(items.count, Int(CPListTemplate.maximumItemCount))
            observed.append(contentsOf: items.compactMap(\.text).filter { $0 != "Anterior" && $0 != "Más" })
            guard let next = items.first(where: { $0.text == "Más" }) else { break }
            next.handler?(next, {})
        }
        XCTAssertEqual(observed, names)
    }
    func testSceneDelegateImplementsConnectionAndDisconnectionSelectors() {
        let scene = CarPlaySceneDelegate()
        XCTAssertTrue(scene.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
        XCTAssertTrue(scene.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
    }
    func testUnavailableSongPresentsANativeCarPlayAlert() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("song.wav"))
        let list = try XCTUnwrap(car.rootTemplate.templates.last as? CPListTemplate)
        let item = try XCTUnwrap(list.sections.first?.items.first as? CPListItem)
        item.handler?(item, {})
        let deadline = Date().addingTimeInterval(4)
        while !(shown.last is CPAlertTemplate) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(shown.last is CPAlertTemplate)
        XCTAssertNotNil(player.issue)
    }
    func testSharedLifecycleRestoresOnceAndDoesNotResetAnActiveSelection() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let services = AppServices(player: player)
        await services.restore()
        player.seek(to: 0.1)
        await services.restore()
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.01)
        XCTAssertFalse(player.isPlaying)
    }
}
