import AVFAudio
import XCTest
import MediaPlayer
import UIKit
import SonoraCore
@testable import Sonora

@MainActor
final class FolderPlaybackTests: XCTestCase {
    private func makePlayer() -> PlaybackController {
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        return PlaybackController(defaults: defaults)
    }
    private func waitUntil(_ predicate: () -> Bool, timeout: Double = 4) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate(), "Playback did not reach the expected state within \(timeout)s")
    }
    private func fixture(_ name: String, duration: Double, at root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.05)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testFolderQueuesNestedTracksAndActuallyAdvancesPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 1, at: root)
        try fixture("CD 2/02.wav", duration: 2, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root)
        XCTAssertEqual(player.queue.tracks.count, 2)
        try await waitUntil { player.current?.relativePath == "CD 2/02.wav" && player.currentTime > 0 }
        XCTAssertEqual(player.queue.current?.relativePath, "CD 2/02.wav")
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 0)
    }

    func testEmptyFolderDoesNotReplaceExistingQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = root.appendingPathComponent("Empty")
        try fixture("01.wav", duration: 2, at: root)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        let previous = player.queue.current?.id
        await player.loadFolder(empty)
        XCTAssertEqual(player.queue.current?.id, previous)
        XCTAssertEqual(player.queue.tracks.count, 1)
        XCTAssertNotNil(player.issue)
    }

    func testPauseBeforePreparationCompletesDoesNotStartAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 3, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        player.play(index: 0)
        player.pause()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.1)
    }

    func testReorderDuringPreparationKeepsTheSelectedTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 3, at: root)
        try fixture("02.wav", duration: 3, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        player.play(index: 1)
        player.move(from: IndexSet(integer: 1), to: 0)
        try await waitUntil { player.isPlaying && !player.isPreparing }
        XCTAssertEqual(player.current?.id, "02.wav")
        XCTAssertEqual(player.currentDetails?.title, "02")
    }

    func testRemovingAlreadyBufferedNextTrackSkipsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["01.wav", "02.wav", "03.wav"] { try fixture(name, duration: 1.8, at: root) }
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.currentTime > 0.2 }
        player.remove(at: IndexSet(integer: 1))
        try await waitUntil({ player.current?.id == "03.wav" && player.currentTime > 0 }, timeout: 3)
        XCTAssertEqual(player.current?.id, "03.wav")
    }

    func testRestoreRetainsPositionWithoutAutoplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 5, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        let first = PlaybackController(defaults: defaults)
        await first.loadFolder(root)
        try await waitUntil { first.currentTime > 0 }
        first.seek(to: 2)
        try await Task.sleep(for: .milliseconds(100))
        first.pause()
        first.stop()
        let restored = PlaybackController(defaults: defaults)
        defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.current?.id, "01.wav")
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.currentTime, 2, accuracy: 0.4)
        restored.togglePlayback()
        try await waitUntil { restored.isPlaying && restored.currentTime > 2 }
    }

    func testCorruptFileIsSkippedAndAllCorruptFolderPreservesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("02.wav", duration: 3, at: root)
        let invalid = root.appendingPathComponent("Invalid")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: root.appendingPathComponent("01.flac"))
        try Data("not audio".utf8).write(to: invalid.appendingPathComponent("01.mp3"))
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        XCTAssertEqual(player.current?.id, "02.wav")
        let ids = player.queue.tracks.map(\.id)
        await player.loadFolder(invalid)
        XCTAssertEqual(player.queue.tracks.map(\.id), ids)
        XCTAssertNotNil(player.issue)
    }

    func testMetadataSidecarCoverAndNowPlayingArePublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(Bundle(for: DecoderTests.self).url(forResource: "fixture", withExtension: "flac"))
        try FileManager.default.copyItem(at: original, to: root.appendingPathComponent("01.flac"))
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        try XCTUnwrap(cover.pngData()).write(to: root.appendingPathComponent("cover.png"))
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        XCTAssertEqual(player.currentDetails?.title, "Señal de prueba")
        XCTAssertEqual(player.currentDetails?.artist, "Sonora Tests")
        XCTAssertNotNil(player.currentDetails?.artwork)
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Señal de prueba")
        XCTAssertNotNil(info?[MPMediaItemPropertyArtwork])
        let embedded = root.appendingPathComponent("Embedded")
        try FileManager.default.createDirectory(at: embedded, withIntermediateDirectories: true)
        let embeddedFixture = try XCTUnwrap(Bundle(for: DecoderTests.self).url(forResource: "fixture-cover", withExtension: "flac"))
        try FileManager.default.copyItem(at: embeddedFixture, to: embedded.appendingPathComponent("01.flac"))
        try XCTUnwrap(cover.pngData()).write(to: embedded.appendingPathComponent("cover.png"))
        await player.loadFolder(embedded, autoPlay: false)
        // The 1024px embedded cover is downsampled to 800px; the sidecar is only 20px.
        XCTAssertEqual(player.currentDetails?.artwork?.size.width, 800)
        XCTAssertEqual(player.currentDetails?.title, "Señal de prueba")
    }

    func testInterruptionRespectsUserPauseAndRouteLossPauses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 6, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { !player.isPlaying }
        player.pause()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(player.isPlaying)
        player.resume()
        try await waitUntil { player.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await waitUntil { !player.isPlaying }
    }

    func testShuffleWithoutRepeatVisitsEachTrackOnceAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["01.wav", "02.wav", "03.wav"] { try fixture(name, duration: 0.7, at: root) }
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        player.shuffle = true
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        var visited: Set<String> = []
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && (player.isPlaying || player.isPreparing) {
            if let id = player.current?.id { visited.insert(id) }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(visited.count, 3)
        XCTAssertFalse(player.isPlaying, "Shuffle must not repeat when repetition is disabled")
    }

    func testSingleTrackStopsAtEndAndCanReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 0.7, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        try await waitUntil { !player.isPlaying }
        XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.05)
        player.resume()
        try await waitUntil { player.isPlaying }
        XCTAssertLessThan(player.currentTime, 0.5)
    }

    func testManualNextIgnoresRepeatOneAndPreservesPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 3, at: root)
        try fixture("02.wav", duration: 3, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer()
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        player.repeatMode = .one
        player.next()
        XCTAssertEqual(player.current?.id, "02.wav", "Repeat one only applies to automatic advancement")
        try await waitUntil { !player.isPreparing }
        XCTAssertFalse(player.isPlaying, "Manual navigation should keep paused playback paused")
        player.previous()
        try await waitUntil { !player.isPreparing }
        XCTAssertEqual(player.current?.id, "01.wav")
        XCTAssertFalse(player.isPlaying)
    }

    func testRestoreKeepsRemovedTracksAndEmptyQueueRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 3, at: root)
        try fixture("02.wav", duration: 3, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        let first = PlaybackController(defaults: defaults)
        defer { first.stop() }
        await first.loadFolder(root, autoPlay: false)
        first.remove(at: IndexSet(integer: 1))
        let restored = PlaybackController(defaults: defaults)
        defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.map(\.id), ["01.wav"])
        restored.remove(at: IndexSet(integer: 0))
        let empty = PlaybackController(defaults: defaults)
        defer { empty.stop() }
        await empty.restoreFolder()
        XCTAssertTrue(empty.queue.tracks.isEmpty)
        XCTAssertFalse(empty.isPlaying)
    }
}
