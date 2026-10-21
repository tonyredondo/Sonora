import AVFAudio
import XCTest
import MediaPlayer
import SFBAudioEngine
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
        try await waitUntil { player.currentSongTools != nil }
        XCTAssertEqual(try XCTUnwrap(player.currentSongTools?.analysis.duration), 2, accuracy: 0.01,
                       "An automatic queue handoff must analyze the newly playing song")
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
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { !player.isPlaying }
        player.pause()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
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
        XCTAssertEqual(Set(restored.library.state.songs.values.map(\.relativePath)), ["01.wav", "02.wav"], "Restoring a reduced queue must retain the full source library")
        restored.remove(at: IndexSet(integer: 0))
        let empty = PlaybackController(defaults: defaults)
        defer { empty.stop() }
        await empty.restoreFolder()
        XCTAssertTrue(empty.queue.tracks.isEmpty)
        XCTAssertFalse(empty.isPlaying)
    }

    func testManualPlayRecoversAfterInterruptionWithoutEndNotification() async throws {
        for mode in [TransitionMode.continuous, .crossfade] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fixture("01.wav", duration: 12, at: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let player = makePlayer(); defer { player.stop() }
            player.setTransition(mode: mode, duration: 1)
            await player.loadFolder(root)
            try await waitUntil { player.isPlaying && player.currentTime > 0.15 }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                           AVAudioSessionInterruptionWasSuspendedKey: true])
            try await waitUntil { !player.isPlaying }
            let position = player.currentTime
            // The user returns and presses Play; iOS need not send an ended event.
            player.togglePlayback()
            try await waitUntil({ player.isPlaying && player.currentTime > position + 0.1 }, timeout: 2)
            XCTAssertNil(player.issue, "A manual Play must start playback or expose its failure")
            let recoveredPosition = player.currentTime
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
            try await waitUntil { player.isPlaying && player.currentTime > recoveredPosition + 0.1 }
        }
    }
    func testSelectingAnotherSongRecoversAfterInterruptionWithoutEndNotification() async throws {
        for mode in [TransitionMode.continuous, .crossfade] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fixture("01.wav", duration: 12, at: root); try fixture("02.wav", duration: 12, at: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let player = makePlayer(); defer { player.stop() }
            player.setTransition(mode: mode, duration: 1)
            await player.loadFolder(root)
            try await waitUntil { player.isPlaying }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await waitUntil { !player.isPlaying }
            player.play(index: 1)
            try await waitUntil({ player.current?.id == "02.wav" && player.isPlaying && player.currentTime > 0.1 }, timeout: 2)
            XCTAssertFalse(player.isPreparing)
            XCTAssertNil(player.issue, "Selecting a song must start playback or expose its failure")
        }
    }

    func testLibrarySelectionRecoversAfterInterruptionWithoutEndNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 12, at: root); try fixture("02.wav", duration: 12, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { !player.isPlaying }
        let song = try XCTUnwrap(player.library.state.songs.values.first { $0.relativePath == "02.wav" })
        player.playSongs([song.id])
        try await waitUntil { player.current?.relativePath == "02.wav" && player.isPlaying && player.currentTime > 0.1 }
        XCTAssertNil(player.issue)
    }
    func testNewInterruptionDuringSelectionStillPausesUntilAnotherPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 12, at: root); try fixture("02.wav", duration: 12, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        player.play(index: 1)
        player.interruptionBegan()
        try await waitUntil { !player.isPreparing }
        XCTAssertFalse(player.isPlaying)
        player.interruptionEnded(shouldResume: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying, "An interruption must not autoplay without a recommendation")
        player.togglePlayback()
        try await waitUntil { player.current?.id == "02.wav" && player.isPlaying && player.currentTime > 0.1 }
    }
    func testLateSystemInterruptionEndCannotRestartAudioAfterManualPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 12, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioPlayer()
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID())")!
        let player = PlaybackController(defaults: defaults, audioPlayer: audio)
        defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying && audio.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { !player.isPlaying && !audio.isPlaying }
        player.resume()
        try await waitUntil { player.isPlaying && audio.isPlaying }
        player.pause()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(audio.isPlaying, "The real engine must obey Pause even if SFB restores its pre-interruption flags")
        XCTAssertFalse(player.isPlaying)
    }

    func testDeniedInterruptionResumeInvalidatesMetadataTransactionPlayIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 12, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioPlayer()
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID())")!
        let player = PlaybackController(defaults: defaults, audioPlayer: audio)
        defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.isPlaying }
        await player.metadataTransaction { _ in
            player.interruptionBegan()
            player.interruptionEnded(shouldResume: false)
        }
        try await waitUntil { !player.isPreparing }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(player.isPlaying, "A deferred metadata reload must not restore an invalidated Play intention")
    }

    func testAutomaticSystemInterruptionResumeRestartsTheRealEngine() async throws {
        for mode in [TransitionMode.continuous, .crossfade] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fixture("01.wav", duration: 12, at: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = AudioPlayer()
            let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.AutoResume.\(UUID())")!, audioPlayer: audio)
            defer { player.stop() }
            player.setTransition(mode: mode, duration: 1)
            await player.loadFolder(root)
            try await waitUntil { player.isPlaying && player.currentTime > 0.1 }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await waitUntil { !player.isPlaying && !audio.isPlaying }
            let position = player.currentTime
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                           AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
            try await waitUntil { player.isPlaying && audio.isPlaying && player.currentTime > position + 0.1 }
        }
    }

    func testDeniedAudioSessionKeepsHealthySelectedSongAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["01.wav", "02.wav", "03.wav"] { try fixture(name, duration: 12, at: root) }
        defer { try? FileManager.default.removeItem(at: root) }
        var deny = false, activations = 0
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.DeniedSession.\(UUID())")!, activateSession: {
            activations += 1
            if deny { throw NSError(domain: NSOSStatusErrorDomain, code: 561017449) }
            try await AudioSessionCoordinator.shared.activate()
        })
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        deny = true; player.play(index: 0)
        try await waitUntil { !player.isPreparing && player.issue != nil }
        XCTAssertEqual(player.current?.id, "01.wav", "An unavailable session does not make the audio file invalid")
        XCTAssertEqual(activations, 1, "Do not walk through healthy songs retrying the same unavailable audio session")
        XCTAssertFalse(player.isPlaying)
        deny = false; player.resume()
        try await waitUntil { player.isPlaying && player.currentTime > 0.1 }
        XCTAssertEqual(player.current?.id, "01.wav")
    }

    func testNewInterruptionDuringFolderActivationWaitsForResumeRecommendation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture("01.wav", duration: 12, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioPlayer()
        var gate: CheckedContinuation<Void, Never>?, activations = 0
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.LoadInterruption.\(UUID())")!, audioPlayer: audio, activateSession: {
            activations += 1
            if activations == 1 { await withCheckedContinuation { gate = $0 } }
            try await AudioSessionCoordinator.shared.activate()
        })
        defer { gate?.resume(); player.stop() }
        let loading = Task { await player.loadFolder(root) }
        try await waitUntil { gate != nil }
        player.interruptionBegan()
        gate?.resume(); gate = nil
        await loading.value
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(player.isPlaying)
        player.interruptionEnded(shouldResume: true)
        try await waitUntil { player.isPlaying && audio.isPlaying && player.currentTime > 0.1 }
    }

    func testLyricOffsetIdentitySeparatesFoldersButSharesLibraryAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")
        let name = "\(UUID()).wav"
        try fixture(name, duration: 3, at: first); try fixture(name, duration: 3, at: second)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop(); player.library.cancelIndexing() }
        var keys: Set<String> = []
        defer { for key in keys { UserDefaults.standard.removeObject(forKey: key) } }
        await player.loadFolder(first, autoPlay: false)
        let track = try XCTUnwrap(player.current), source = try XCTUnwrap(player.libraryID(for: track)).components(separatedBy: "\0")[0]
        let key = player.lyricsOffsetKey(for: track); keys.insert(key)
        XCTAssertFalse(key.contains("\0"), "Preference keys must not contain the internal source separator")
        UserDefaults.standard.set(2.0, forKey: key)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 2)
        let repair = LyricsRepairSession(player: player, track: track.withSource(source))
        XCTAssertTrue(repair.canListen, "The library alias of the current audio must allow auditioning repairs")
        let alias = player.lyricsOffsetKey(for: track.withSource(source)); keys.insert(alias)
        XCTAssertEqual(alias, key, "One file must retain its adjustment through folder or library playback")
        XCTAssertEqual(UserDefaults.standard.double(forKey: alias), 2)
        await player.loadFolder(second, autoPlay: false)
        let other = player.lyricsOffsetKey(for: player.current); keys.insert(other)
        XCTAssertNotEqual(other, key, "Identical relative paths in different sources must be independent")
        XCTAssertEqual(UserDefaults.standard.double(forKey: other), 0)
        XCTAssertFalse(repair.canListen, "A matching filename in another source must not enable the original repair preview")
    }

    func testLyricOffsetMigratesQualifiedLegacyValuesWithoutReplacingNewOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "\(UUID()).wav"
        try fixture(name, duration: 3, at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        let track = try XCTUnwrap(player.current), identity = try XCTUnwrap(player.libraryID(for: track))
        let key = player.lyricsOffsetKey(for: track)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Registration is process-local and can expose a legacy key even when
        // the preferences daemon cannot persist its embedded NUL separator.
        UserDefaults.standard.register(defaults: ["lyricsOffset." + track.id: 8.0])
        XCTAssertEqual(player.lyricsOffsetKey(for: track), key)
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "A relative-path preference has no proven source owner")
        UserDefaults.standard.register(defaults: ["lyricsOffset." + identity: 1.5])
        XCTAssertEqual(player.lyricsOffsetKey(for: track), key)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 1.5)
        UserDefaults.standard.set(2.0, forKey: key)
        XCTAssertEqual(player.lyricsOffsetKey(for: track), key)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 2, "A new adjustment must win over its legacy value")
    }

    func testEnqueueLibraryAliasMovesPrimarySongButKeepsOtherSourcesDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")
        for name in ["A.wav", "B.wav", "C.wav"] { try fixture(name, duration: 3, at: first) }
        try fixture("C.wav", duration: 3, at: second)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(first, autoPlay: false)
        let track = try XCTUnwrap(player.queue.tracks.last)
        let source = try XCTUnwrap(player.library.state.sources.first?.id)
        player.enqueue(track.withSource(source), playNext: false)
        XCTAssertEqual(player.queue.tracks.map(\.relativePath), ["A.wav", "B.wav", "C.wav"])
        player.enqueue(track.withSource(source), playNext: true)
        XCTAssertEqual(player.queue.tracks.map(\.relativePath), ["A.wav", "C.wav", "B.wav"])
        let other = try player.library.register(ScopedFolder(second), tracks: [track])
        player.enqueue(track.withSource(other), playNext: false)
        XCTAssertEqual(player.queue.tracks.count, 4)
        XCTAssertEqual(player.queue.tracks.last?.sourceID, other)
    }

    func testPinnedSongActionRetainsOriginalSourceAcrossCarPlayQueueReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")
        try fixture("song.wav", duration: 8, at: first); try fixture("song.wav", duration: 8, at: second)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = makePlayer(); defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(first, autoPlay: false)
        let raw = try XCTUnwrap(player.current), original = try await player.readMetadata(for: raw)
        let request = SongActionRequest(player: player, track: raw, action: .information)
        XCTAssertNotNil(request.track.sourceID)
        let otherSource = try player.library.register(ScopedFolder(second), tracks: [raw])
        let other = raw.withSource(otherSource)
        player.playSongs([other.id]) // Same path as CarPlayCoordinator.play.
        try await waitUntil { player.current?.id == other.id && !player.isPreparing }
        player.pause()
        let pinned = try await player.readMetadata(for: request.track)
        XCTAssertEqual(pinned.fingerprint, original.fingerprint)
        try await player.saveMetadata(for: request.track, expected: original.fingerprint, patch: MetadataPatch(values: [.title: "Pinned original"]))
        let saved = try await player.readMetadata(for: request.track), untouched = try await player.readMetadata(for: other)
        XCTAssertEqual(saved.values[.title], "Pinned original")
        XCTAssertNotEqual(untouched.values[.title], "Pinned original")
        player.playForLyricsEditing(request.track, at: 1)
        try await waitUntil { player.isEditingTrackCurrent(request.track) && player.isPlaying && player.currentTime > 1 }
    }

}
