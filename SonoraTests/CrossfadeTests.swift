import AVFAudio
import SFBAudioEngine
import XCTest
@testable import Sonora

@MainActor
final class CrossfadeTests: XCTestCase {
    func testLateIncomingPreparationDoesNotFadeOutOrConsumeTheNextHead() throws {
        let url = try XCTUnwrap(Bundle(for: DecoderTests.self).url(forResource: "fixture", withExtension: "wav"))
        func drain(_ decoder: any PCMDecoding) throws -> [Float] {
            defer { try? decoder.close() }
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
            var samples: [Float] = []
            repeat {
                try decoder.decode(into: buffer, length: buffer.frameCapacity)
                samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                XCTAssertLessThan(samples.count, 200000, "Fixture drain must remain bounded")
                if samples.count >= 200000 { break }
            } while buffer.frameLength == buffer.frameCapacity
            return samples
        }
        let original = try drain(NormalizedPCMDecoder(AudioDecoders.open(url)))
        let handoff = CrossfadeHandoff()
        XCTAssertTrue(handoff.beginPreparation())
        let outgoing = try NormalizedPCMDecoder(AudioDecoders.open(url))
        let played = try drain(CrossfadeDecoder(outgoing, handoff: handoff, duration: 12))
        XCTAssertEqual(played, original, "Waiting for a provider must preserve the entire outgoing audio")
        XCTAssertNil(handoff.takeForEnqueue())
        let incoming = try NormalizedPCMDecoder(AudioDecoders.open(url))
        defer { try? incoming.close() }
        let details = TrackDetails(title: "Late fixture", artist: "Sonora", album: "Tests", duration: Double(incoming.length) / 48000,
                                   format: "WAV", sampleRate: 44100, artwork: nil)
        handoff.supply(TransitionTrack(id: "next", prepared: PreparedTrack(decoder: incoming, details: details)))
        let transfer = try XCTUnwrap(handoff.takeForEnqueue())
        XCTAssertEqual(transfer.0.prepared.decoder.position, 0)
        guard case .notReady = transfer.1 else { XCTFail("A late provider must report continuous playback"); return }
        XCTAssertNil(handoff.takeForEnqueue(), "Decoder ownership can only transfer once")
    }

    func testResamplingPreservesFrameCountAndAlignsTheStart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        input.frameLength = input.frameCapacity
        for channel in 0..<2 { input.floatChannelData![channel].initialize(repeating: 0.2, count: 88200) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: input)
        let decoder = try NormalizedPCMDecoder(AudioDecoders.open(url))
        defer { try? decoder.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
        var values: [Float] = []
        repeat {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            values.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        } while buffer.frameLength == buffer.frameCapacity
        print("RESAMPLE: \(values.count) frames; first signal at \(values.firstIndex { $0 > 0.05 } ?? -1)")
        XCTAssertEqual(values.count, 96000)
        XCTAssertEqual(decoder.position, 96000)
        XCTAssertEqual(values.firstIndex { $0 > 0.05 }, 0)
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var sampleRate: Double = 0
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            lock.lock(); defer { lock.unlock() }
            sampleRate = buffer.format.sampleRate
            let count = min(Int(buffer.frameLength), 400000 - samples.count)
            if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
        }
        func snapshot() -> ([Float], Double) { lock.lock(); defer { lock.unlock() }; return (samples, sampleRate) }
    }

    private func captureJoin(duration: Double, mixedFormats: Bool = false, preamp: Float? = nil) async throws -> (samples: [Float], rate: Double, incomingTime: Double) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2 {
            let rate = index == 1 && mixedFormats ? 48000.0 : 44100.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: index == 1 && mixedFormats ? 1 : 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * duration))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel].initialize(repeating: index == 0 ? 0.2 : 0.4, count: Int(buffer.frameLength))
            }
            try AVAudioFile(forWriting: root.appendingPathComponent("0\(index + 1).wav"), settings: format.settings).write(from: buffer)
        }
        let suite = "SonoraTests.Crossfade.\(UUID().uuidString)", audio = AudioPlayer()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: ["mode": "crossfade", "duration": 1]), forKey: "transitionSettings")
        if let preamp {
            defaults.set(try JSONSerialization.data(withJSONObject: ["enabled": true, "gains": Array(repeating: 0, count: 10), "preamp": preamp]), forKey: "equalizerSettings")
        }
        let controller = PlaybackController(defaults: defaults, audioPlayer: audio), capture = Capture()
        defer { controller.stop() }
        let node: AVAudioNode = preamp == nil ? audio.sourceNode : audio.mainMixerNode
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { node.removeTap(onBus: 0) }
        await controller.loadFolder(root)
        XCTAssertNil(controller.issue)
        var incomingTime: Double?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if controller.current?.relativePath == "02.wav" {
                if incomingTime == nil { incomingTime = controller.currentTime }
                if !controller.isPlaying && !controller.isPreparing { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.current?.relativePath, "02.wav")
        try await Task.sleep(for: .milliseconds(100))
        let (samples, rate) = capture.snapshot()
        let first = try XCTUnwrap(samples.firstIndex { $0 > 0.05 }), last = try XCTUnwrap(samples.lastIndex { $0 > 0.05 })
        print("CROSSFADE: \(last - first + 1) frames at \(rate) Hz; incoming position \(incomingTime ?? -1); \(controller.lastTransition?.description ?? "no transition")")
        return (Array(samples[first...last]), rate, try XCTUnwrap(incomingTime))
    }

    func testFolderCrossfadeRendersOverlapAndIncomingPlayhead() async throws {
        let result = try await captureJoin(duration: 2)
        XCTAssertEqual(Double(result.samples.count), result.rate * 3, accuracy: 2)
        guard result.samples.count > Int(result.rate * 2.5) else { return }
        XCTAssertEqual(result.samples[Int(result.rate * 0.5)], 0.2, accuracy: 0.001)
        XCTAssertEqual(result.samples[Int(result.rate * 1.5)], 0.3, accuracy: 0.005)
        XCTAssertEqual(result.samples[Int(result.rate * 2.5)], 0.4, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.incomingTime, 0.98)
    }

    func testShortFilesClampOverlapWithoutLosingTheIncomingTail() async throws {
        let result = try await captureJoin(duration: 0.4)
        XCTAssertEqual(Double(result.samples.count), result.rate * 0.6, accuracy: 2)
        XCTAssertGreaterThanOrEqual(result.incomingTime, 0.18)
    }

    func testDifferentSourceFormatsCrossfadeThroughTheEnabledEQ() async throws {
        let result = try await captureJoin(duration: 2, mixedFormats: true, preamp: -6)
        let gain = Float(pow(10, -6.0 / 20))
        // Preserve the native player's equal-power mono-to-stereo level.
        let incoming = Float(0.4 / sqrt(2.0))
        XCTAssertGreaterThan(result.samples.count, Int(result.rate * 2.5))
        guard result.samples.count > Int(result.rate * 2.5) else { return }
        XCTAssertEqual(result.samples[Int(result.rate * 0.5)], 0.2 * gain, accuracy: 0.01)
        XCTAssertEqual(result.samples[Int(result.rate * 1.5)], (0.2 + incoming) * 0.5 * gain, accuracy: 0.01)
        XCTAssertEqual(result.samples[Int(result.rate * 2.5)], incoming * gain, accuracy: 0.01)
    }
}
