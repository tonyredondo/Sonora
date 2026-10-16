import AVFAudio
import SFBAudioEngine
import XCTest
@testable import Sonora

@MainActor final class ListeningControlsTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var channels = [[Float](), [Float]()]
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData, buffer.format.channelCount >= 2 else { return }
            lock.lock(); defer { lock.unlock() }
            let count = min(Int(buffer.frameLength), 96000 - channels[0].count)
            if count > 0 { for channel in 0..<2 { channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: count)) } }
        }
        func snapshot() -> [[Float]] { lock.lock(); defer { lock.unlock() }; return channels }
    }
    private func write(_ url: URL, duration: Double = 3, rate: Double = 48000, channels: AVAudioChannelCount = 2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * duration))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float((channel == 0 ? 0.08 : 0.04) * sin(2 * .pi * 1000 * Double(frame) / rate))
            }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
    private func levels(mode: String, balance: Float = 0, gain: Double? = -6, peak: Double = 0.1, rate: Double = 48000, preamp: Float? = nil) async throws -> (Double, Double) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("signal.wav"); try write(url, rate: rate)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.replayGainTrackGain = gain; file.metadata.replayGainAlbumGain = -12
        file.metadata.replayGainTrackPeak = peak; file.metadata.replayGainAlbumPeak = 0.1
        try file.writeMetadata()
        XCTAssertEqual(try AudioFile(readingPropertiesAndMetadataFrom: url).metadata.replayGainTrackGain, gain)
        let suite = "SonoraTests.Listening.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: ["normalization": mode, "balance": balance]), forKey: "listeningSettings")
        if let preamp { defaults.set(try JSONSerialization.data(withJSONObject: ["enabled": true, "gains": Array(repeating: 0, count: 10), "preamp": preamp]), forKey: "equalizerSettings") }
        let audio = AudioPlayer(), capture = Capture(), player = PlaybackController(defaults: defaults, audioPlayer: audio)
        defer { player.stop() }
        audio.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { audio.mainMixerNode.removeTap(onBus: 0) }
        await player.loadFolder(root)
        let deadline = Date().addingTimeInterval(4)
        while capture.snapshot()[0].count < 20000 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let samples = capture.snapshot()
        let first = try XCTUnwrap(samples[0].indices.first { abs(samples[0][$0]) + abs(samples[1][$0]) > 0.001 }) + 2000
        let last = min(first + 12000, samples[0].count)
        XCTAssertGreaterThan(last - first, 4000)
        func rms(_ channel: Int) -> Double { sqrt(samples[channel][first..<last].reduce(0) { $0 + Double($1 * $1) } / Double(last - first)) }
        return (rms(0), rms(1))
    }
    func testReplayGainChangesActualPlayerOutputAndPeakProtection() async throws {
        let original = try await levels(mode: "off")
        let track = try await levels(mode: "track"), album = try await levels(mode: "album")
        XCTAssertEqual(track.0 / original.0, pow(10, -6.0 / 20), accuracy: 0.02)
        XCTAssertEqual(album.1 / original.1, pow(10, -12.0 / 20), accuracy: 0.02)
        let missing = try await levels(mode: "track", gain: nil)
        XCTAssertEqual(missing.0 / original.0, 1, accuracy: 0.02)
        let limited = try await levels(mode: "track", gain: 12, peak: 0.8)
        XCTAssertEqual(limited.0 / original.0, 1.25, accuracy: 0.03)
    }
    func testBalanceChangesActualStereoOutput() async throws {
        let left = try await levels(mode: "off", balance: -1), right = try await levels(mode: "off", balance: 1)
        XCTAssertGreaterThan(left.0, 0.01); XCTAssertLessThan(left.1, 0.0001)
        XCTAssertGreaterThan(right.1, 0.01); XCTAssertLessThan(right.0, 0.0001)
    }
    func testGainBalanceAndEQWorkTogetherAtTheInitial44100Format() async throws {
        let original = try await levels(mode: "off", rate: 44100)
        let adjusted = try await levels(mode: "track", balance: 0.5, rate: 44100, preamp: -6)
        XCTAssertEqual(adjusted.0 / original.0, pow(10, -12.0 / 20) * 0.5, accuracy: 0.015)
        XCTAssertEqual(adjusted.1 / original.1, pow(10, -12.0 / 20), accuracy: 0.015)
        XCTAssertEqual(adjusted.0, adjusted.1, accuracy: 0.001)
    }
    func testSettingsAndTimerPersistAndInvalidLoudnessDoesNotAmplify() throws {
        let suite = "SonoraTests.ListeningPersistence.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        let date = Date().addingTimeInterval(60)
        player.setListening(normalization: .album, balance: 0.4); player.setSleepTimer(.deadline(date))
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        XCTAssertEqual(restored.listeningSettings.normalization, .album)
        XCTAssertEqual(restored.listeningSettings.balance, 0.4, accuracy: 0.001)
        XCTAssertEqual(restored.sleepTimer, .deadline(date))
        XCTAssertEqual(ReplayGain(trackGain: .nan, trackPeak: .infinity).multiplier(for: .track), 1)
        XCTAssertEqual(ListeningSettings(balance: .nan).validated.balance, 0)
    }
    func testManualSkipCancelsEndTimerAndChangingListeningPreservesPause() async throws {
        try await withPlayer(duration: 2) { player, root in
            await player.loadFolder(root)
            player.setSleepTimer(.endOfTrack(try XCTUnwrap(player.current?.id))); player.next()
            try await waitUntil { player.current?.id == "02.wav" && player.isPlaying }
            XCTAssertNil(player.sleepTimer)
            player.pause(); let position = player.currentTime
            player.setListening(normalization: .track, balance: -0.4)
            try await waitUntil { !player.isPreparing }
            XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.currentTime, position, accuracy: 0.03)
        }
    }
    func testSleepDeadlinePausesBeforeFileEndsAndClearsItself() async throws {
        try await withPlayer(duration: 4) { player, root in
            await player.loadFolder(root)
            player.setSleepTimer(.deadline(Date().addingTimeInterval(0.4)))
            try await Task.sleep(for: .seconds(1.2))
            XCTAssertFalse(player.isPlaying); XCTAssertNil(player.sleepTimer)
            XCTAssertLessThan(player.currentTime, 2)
            player.resume(); try await waitUntil { player.isPlaying }
            try await Task.sleep(for: .milliseconds(300)); XCTAssertTrue(player.isPlaying)
        }
    }
    func testSleepAtTrackEndDisablesOverlapAndStopsBeforeSuccessor() async throws {
        try await withPlayer(duration: 1.2) { player, root in
            player.setTransition(mode: .crossfade, duration: 1)
            await player.loadFolder(root)
            try await waitUntil { player.currentTime > 0 }
            player.setSleepTimer(.endOfTrack(try XCTUnwrap(player.current?.id)))
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(player.current?.id, "01.wav"); XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.05); XCTAssertNil(player.sleepTimer)
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    private func withPlayer(duration: Double, _ body: (PlaybackController, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["01.wav", "02.wav"] { try write(root.appendingPathComponent(name), duration: duration) }
        let suite = "SonoraTests.Sleep.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        let player = PlaybackController(defaults: defaults); defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        try await body(player, root)
    }
}
