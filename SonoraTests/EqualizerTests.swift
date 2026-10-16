import AVFAudio
import SFBAudioEngine
import XCTest
@testable import Sonora

@MainActor
final class EqualizerTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var rate: Double = 0
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            lock.lock(); defer { lock.unlock() }
            rate = buffer.format.sampleRate
            let count = min(Int(buffer.frameLength), 100000 - samples.count)
            if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
        }
        func snapshot() -> ([Float], Double) {
            lock.lock(); defer { lock.unlock() }; return (samples, rate)
        }
    }

    private func amplitudes(enabled: Bool, gains: [Float], preamp: Float, sampleRate: Double = 44100, channels: AVAudioChannelCount = 2) async throws -> (Double, Double) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 1.5))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / format.sampleRate
                buffer.floatChannelData![channel][frame] = Float(0.08 * (sin(2 * .pi * 100 * time) + sin(2 * .pi * 1000 * time)))
            }
        }
        try AVAudioFile(forWriting: root.appendingPathComponent("01.wav"), settings: format.settings).write(from: buffer)
        let suite = "SonoraTests.EQ.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: ["enabled": enabled, "gains": gains, "preamp": preamp]), forKey: "equalizerSettings")
        let audio = AudioPlayer(), capture = Capture()
        let controller = PlaybackController(defaults: defaults, audioPlayer: audio)
        defer { controller.stop() }
        audio.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { audio.mainMixerNode.removeTap(onBus: 0) }
        await controller.loadFolder(root)
        XCTAssertNil(controller.issue)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let (samples, rate) = capture.snapshot()
            if let first = samples.firstIndex(where: { abs($0) > 0.001 }), samples.count >= first + Int(rate * 0.3) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let (samples, rate) = capture.snapshot()
        let first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.001 }, "No rendered signal: \(samples.count)frames at\(rate),enabled=\(enabled),playing=\(controller.isPlaying),time=\(controller.currentTime),ready=\(audio.isReady),nativePlaying=\(audio.isPlaying),issue=\(controller.issue ?? "nil")") + Int(rate / 10)
        print("EQ CAPTURE: first=\(first - Int(rate / 10)),total=\(samples.count),rate=\(rate),enabled=\(enabled)")
        let count = Int(rate / 5)
        XCTAssertGreaterThanOrEqual(samples.count, first + count)
        guard samples.count >= first + count else { return (0, 0) }
        func amplitude(_ frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for frame in 0..<count {
                let phase = 2 * .pi * frequency * Double(frame) / rate
                real += Double(samples[first + frame]) * cos(phase)
                imaginary += Double(samples[first + frame]) * sin(phase)
            }
            return 2 * hypot(real, imaginary) / Double(count)
        }
        return (amplitude(100), amplitude(1000))
    }

    func testSavedBandGainChangesActualFolderPlayerOutput() async throws {
        let (bass, mid) = try await amplitudes(enabled: true, gains: [0, 0, 0, 0, 0, -12, 0, 0, 0, 0], preamp: 0)
        XCTAssertEqual(bass, 0.08, accuracy: 0.006)
        XCTAssertEqual(mid / bass, pow(10, -12.0 / 20), accuracy: 0.04)
    }

    func testPreampChangesActualPlayerLevelAndBypassRestoresOriginal() async throws {
        let (bass, mid) = try await amplitudes(enabled: true, gains: Array(repeating: 0, count: 10), preamp: -6)
        XCTAssertEqual(bass, 0.08 * pow(10, -6.0 / 20), accuracy: 0.004)
        XCTAssertEqual(mid, bass, accuracy: 0.003)
        let (originalBass, originalMid) = try await amplitudes(enabled: false, gains: Array(repeating: -12, count: 10), preamp: -12)
        XCTAssertEqual(originalBass, 0.08, accuracy: 0.004)
        XCTAssertEqual(originalMid, 0.08, accuracy: 0.004)
    }

    func testEQSurvivesSourceRateAndChannelReconfiguration() async throws {
        let (bass, mid) = try await amplitudes(enabled: true, gains: [0, 0, 0, 0, 0, -12, 0, 0, 0, 12], preamp: 0, sampleRate: 22050, channels: 1)
        let (originalBass, originalMid) = try await amplitudes(enabled: false, gains: Array(repeating: 0, count: 10), preamp: 0, sampleRate: 22050, channels: 1)
        // Compare the same mono-to-stereo mixer path: its pan law changes each channel's level.
        XCTAssertGreaterThan(originalBass, 0.04)
        XCTAssertEqual(bass / originalBass, 1, accuracy: 0.06)
        XCTAssertEqual(mid / originalMid, pow(10, -12.0 / 20), accuracy: 0.04)
    }

    func testManualCurveAndDisabledStateSurviveRelaunch() throws {
        let suite = "SonoraTests.EQ.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = AudioPlayer()
        do {
            let equalizer = AudioEqualizer(defaults: defaults, player: audio)
            equalizer.select(.bass); equalizer.setEnabled(true)
            equalizer.setGain(5, to: 2.5); equalizer.setPreamp(-4.5); equalizer.setEnabled(false)
        }
        let restored = AudioEqualizer(defaults: defaults, player: AudioPlayer())
        XCTAssertFalse(restored.settings.enabled)
        XCTAssertEqual(restored.settings.gains[0], 6)
        XCTAssertEqual(restored.settings.gains[5], 2.5)
        XCTAssertEqual(restored.settings.preamp, -4.5)
        XCTAssertNil(restored.preset)
    }
}
