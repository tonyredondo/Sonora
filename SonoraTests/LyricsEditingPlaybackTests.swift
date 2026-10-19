import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

final class LyricsEditingPlaybackTests: XCTestCase {
    @MainActor func testAuditionUsesPinnedSongPreservesQueueAndDoesNotSaveDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000)); buffer.frameLength = 160000
        buffer.int16ChannelData![0].initialize(repeating: 0, count: 160000)
        for name in ["first.wav", "second.wav"] {
            try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false).write(from: buffer)
        }
        let suite = "SonoraTests.LyricsEditing.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        let track = try XCTUnwrap(player.queue.tracks.last)
        let original = try await player.readMetadata(for: track)
        let queue = player.queue.tracks.map(\.id)
        XCTAssertFalse(player.isEditingTrackCurrent(track))
        player.playForLyricsEditing(track, at: 2)
        for _ in 0..<100 {
            if player.isPlaying && player.currentTime > 2.05 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(player.isEditingTrackCurrent(track)); XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 2.05)
        player.pause(); XCTAssertFalse(player.isPlaying)
        player.seek(to: 5); XCTAssertEqual(player.currentTime, 5, accuracy: 0.05)
        player.playForLyricsEditing(track)
        for _ in 0..<60 {
            if player.isPlaying && player.currentTime > 5.05 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(player.isPlaying); XCTAssertGreaterThan(player.currentTime, 5.05)
        player.pause()
        XCTAssertEqual(player.queue.tracks.map(\.id), queue, "Audition must preserve the queue and not add duplicates")
        let after = try await player.readMetadata(for: track)
        XCTAssertEqual(after.fingerprint, original.fingerprint)
        XCTAssertEqual(after.values, original.values, "Playback never writes the metadata draft")
        player.play(index: 0)
        XCTAssertFalse(player.isEditingTrackCurrent(track), "A pinned draft must not follow another song")
        player.remove(at: IndexSet(integer: 1))
        player.playForLyricsEditing(track, at: 4)
        for _ in 0..<100 {
            if player.isPlaying && player.currentTime > 4.05 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(player.isEditingTrackCurrent(track)); XCTAssertGreaterThan(player.currentTime, 4.05)
        XCTAssertEqual(player.queue.tracks.map(\.id), queue, "A song outside the queue is added once without removing the others")
    }
}
