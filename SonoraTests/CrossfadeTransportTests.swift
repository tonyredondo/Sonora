import AVFAudio
import XCTest
@testable import Sonora

@MainActor
final class CrossfadeTransportTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, timeout: Double = 4) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Crossfade transport did not reach the expected state")
    }
    private func withFolder(_ names: [String], duration: Double,
                            action: @MainActor (PlaybackController, URL, UserDefaults) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in names {
            let url = root.appendingPathComponent(name)
            if !name.hasSuffix("wav") { try Data("not audio".utf8).write(to: url); continue }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48000 * duration))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.05)
                }
            }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        }
        let suite = "SonoraTests.CrossfadeTransport.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        let player = PlaybackController(defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        player.setTransition(mode: .crossfade, duration: 1)
        try await action(player, root, defaults)
    }

    func testRemovingBufferedIncomingAndSeekingWhilePaused() async throws {
        try await withFolder(["01.wav", "02.wav", "03.wav"], duration: 1.6) { player, root, _ in
            await player.loadFolder(root)
            try await waitUntil { player.currentTime > 0.2 }
            player.pause(); player.remove(at: IndexSet(integer: 1)); player.seek(to: 1)
            try await waitUntil { !player.isPreparing }
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.currentTime, 1, accuracy: 0.02)
            player.resume()
            var visited: Set<String> = []
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let id = player.current?.id { visited.insert(id) }
                if player.current?.id == "03.wav" && player.currentTime > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(player.current?.id, "03.wav")
            XCTAssertFalse(visited.contains("02.wav"), "A removed decoded head must not reach playback")
            XCTAssertTrue(player.isPlaying)
        }
    }
    func testModeAndDurationPersistAndManualNextRespectsPauseAndRepeatOne() async throws {
        try await withFolder(["01.wav", "02.wav"], duration: 3) { player, root, defaults in
            await player.loadFolder(root)
            try await waitUntil { player.currentTime > 0.2 }
            player.pause(); let position = player.currentTime
            player.repeatMode = .one; player.setTransition(mode: .continuous, duration: 12)
            try await waitUntil { !player.isPreparing }
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.currentTime, position, accuracy: 0.1)
            let restored = PlaybackController(defaults: defaults)
            defer { restored.stop() }
            XCTAssertEqual(restored.transitionSettings, TransitionSettings(mode: .continuous, duration: 12))
            player.next()
            try await waitUntil { !player.isPreparing }
            XCTAssertEqual(player.current?.id, "02.wav")
            XCTAssertFalse(player.isPlaying)
            player.setTransition(mode: .crossfade, duration: 1); player.resume()
            try await waitUntil { player.isPlaying && player.currentTime > 0 }
            player.interruptionBegan()
            XCTAssertFalse(player.isPlaying)
            player.pause(); player.interruptionEnded(shouldResume: true)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(player.isPlaying)
        }
    }
    func testShuffleVisitsEachTrackOnceAndStops() async throws {
        try await withFolder(["01.wav", "02.wav", "03.wav", "04.wav"], duration: 0.5) { player, root, _ in
            player.shuffle = true
            await player.loadFolder(root)
            try await waitUntil { player.isPlaying }
            var visited: Set<String> = []
            let deadline = Date().addingTimeInterval(4)
            repeat {
                if let id = player.current?.id { visited.insert(id) }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline && (player.isPlaying || player.isPreparing)
            XCTAssertEqual(visited.count, 4)
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isPreparing)
        }
    }
    func testCorruptIncomingIsSkippedAndAnUnplayableTailStops() async throws {
        for hasFinalTrack in [true, false] {
            let names = ["01.wav", "02.mp3"] + (hasFinalTrack ? ["03.wav"] : [])
            try await withFolder(names, duration: 0.7) { player, root, _ in
                await player.loadFolder(root)
                try await waitUntil { player.isPlaying && player.currentTime > 0 }
                try await waitUntil { !player.isPlaying && !player.isPreparing }
                print("CORRUPT TAIL: finalTrack=\(hasFinalTrack) current=\(player.current?.id ?? "none") time=\(player.currentTime) issue=\(player.issue ?? "none")")
                XCTAssertEqual(player.current?.id, hasFinalTrack ? "03.wav" : "01.wav")
                XCTAssertTrue(player.issue?.contains("02.mp3") == true)
                XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.05)
            }
        }
    }
    func testFolderReplacementCancelsTheOldOverlap() async throws {
        try await withFolder(["01.wav", "02.wav"], duration: 1) { player, root, _ in
            await player.loadFolder(root)
            try await waitUntil { player.isPlaying }
            let other = root.appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("01.wav"), to: other.appendingPathComponent("new.wav"))
            await player.loadFolder(other)
            try await waitUntil { player.isPlaying }
            try await waitUntil { !player.isPlaying && !player.isPreparing }
            XCTAssertEqual(player.current?.id, "new.wav")
            XCTAssertEqual(player.queue.tracks.count, 1)
            XCTAssertNil(player.lastTransition)
        }
    }
    func testSourceTruncatedDuringPlaybackReportsFailureAndContinues() async throws {
        try await withFolder(["01.wav", "02.wav"], duration: 4) { player, root, _ in
            await player.loadFolder(root)
            try await waitUntil { player.currentTime > 0.2 }
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("01.wav"))
            try handle.truncate(atOffset: 0); try handle.close()
            try await waitUntil { player.current?.id == "02.wav" && player.isPlaying }
            XCTAssertNotNil(player.issue, "Premature EOF must be reported instead of silently losing the source tail")
            XCTAssertLessThan(player.currentTime, 0.5, "A failed outgoing track must not consume the healthy incoming head")
        }
    }
}
