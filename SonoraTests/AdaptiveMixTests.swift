import AVFAudio
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class AdaptiveMixTests: XCTestCase {
    private func signal(_ url: URL, phase: Double, duration: Double, bpm: Double = 120, pulsed: Bool = true) throws {
        let format = NormalizedPCMDecoder.format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48000 * duration))!
        buffer.frameLength = buffer.frameCapacity
        let period = 60 / bpm
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / 48000, relative = time - phase
            let beatTime = relative - floor(relative / period) * period
            let value: Float = pulsed ? (relative >= 0 && beatTime < 0.018 ? Float(0.15 * sin(2 * .pi * 880 * beatTime) * exp(-beatTime / 0.008)) : 0) : 0.1
            for channel in 0..<2 { buffer.floatChannelData![channel][frame] = value }
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
    private func withFolder(_ body: (URL, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, root.appendingPathComponent("01.wav"), root.appendingPathComponent("02.wav"))
    }
    private func musicalSignal(_ url: URL) throws {
        var energy = [Double](repeating: 0.02, count: 1200)
        for beat in 0..<24 {
            for (fraction, amplitude) in [(0.0, 0.4), (0.5, 0.22), (0.75, 0.11)] {
                let time = Double(beat) * 0.5 + fraction * 0.5 + 0.025 * sin(Double(beat) * 1.7)
                let center = Int(time * 100)
                for i in max(0, center - 4)...min(1199, center + 4) {
                    energy[i] += amplitude * (0.8 + 0.2 * cos(Double(beat))) * exp(-pow((Double(i) / 100 - time) / 0.018, 2))
                }
            }
        }
        let format = NormalizedPCMDecoder.format
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for second in 0..<12 {
            for frame in 0..<48000 {
                let value = Float(energy[second * 100 + frame / 480] * sin(Double(frame) * 2 * .pi * 440 / 48000))
                for channel in 0..<2 { buffer.floatChannelData![channel][frame] = value }
            }
            try file.write(from: buffer)
        }
    }
    func testPCMAnalysisFindsSteadyPulseWithinBoundedBudgetAndRejectsUnpulsedAudio() async throws {
        try await withFolder { _, first, second in
            try signal(first, phase: 0.1, duration: 12.1)
            let result = try AudioRhythmAnalyzer.analyze(first)
            XCTAssertEqual(try XCTUnwrap(result.head).bpm, 120, accuracy: 0.8)
            XCTAssertEqual(try XCTUnwrap(result.tail).bpm, 120, accuracy: 0.8)
            XCTAssertLessThan(result.milliseconds, 500)
            print("ADAPTIVE ANALYSIS: 16secondsofPCM in\(result.milliseconds)ms;head\(result.head!.bpm)tail\(result.tail!.bpm)")
            try signal(second, phase: 0, duration: 12, pulsed: false)
            let rejected = try AudioRhythmAnalyzer.analyze(second)
            XCTAssertNil(rejected.head); XCTAssertNil(rejected.tail)
            XCTAssertNil(rejected.headBPM); XCTAssertNil(rejected.tailBPM)
        }
    }
    func testEstimatedPCMAlignsTheIncomingBeatAndTransfersItsConsumedHead() async throws {
        try await withFolder { _, first, second in
            try musicalSignal(first)
            try signal(second, phase: 0.25, duration: 16)
            let analysis = try AudioRhythmAnalyzer.analyze(first)
            let grid = try XCTUnwrap(analysis.tail, "Offbeats and timing variation still provide a useful estimated phase")
            XCTAssertLessThan(grid.confidence, 0.72)
            XCTAssertEqual(try XCTUnwrap(analysis.tailBPM), 120, accuracy: 2)
            XCTAssertLessThan(analysis.milliseconds, 500)
            let incoming = try NormalizedPCMDecoder(AudioDecoders.open(second))
            defer { try? incoming.close() }
            var details = TrackDetails(title: "Incoming", artist: "Sonora Tests", album: "Tests",
                duration: 16, format: "WAV", sampleRate: 48000, artwork: nil)
            details.rhythm = try AudioRhythmAnalyzer.analyze(second)
            let handoff = CrossfadeHandoff()
            XCTAssertTrue(handoff.beginPreparation())
            handoff.supply(TransitionTrack(id: "02", prepared: PreparedTrack(decoder: incoming, details: details)))
            let decoder = CrossfadeDecoder(try NormalizedPCMDecoder(AudioDecoders.open(first)),
                handoff: handoff, duration: 5, adaptive: analysis)
            defer { try? decoder.close() }
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
            var frames = 0
            repeat {
                try decoder.decode(into: buffer, length: buffer.frameCapacity)
                frames += Int(buffer.frameLength)
                XCTAssertTrue(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength)).allSatisfy { $0.isFinite && abs($0) <= 1 })
            } while buffer.frameLength == buffer.frameCapacity
            let transfer = try XCTUnwrap(handoff.takeForEnqueue())
            guard case .adaptiveEstimate(let seconds, let bpm) = transfer.1 else {
                return XCTFail("The estimated beat phase must align the incoming audio")
            }
            XCTAssertEqual(bpm, 120, accuracy: 2)
            XCTAssertGreaterThan(seconds, 4); XCTAssertLessThanOrEqual(seconds, 5)
            let skip = Double(incoming.position) / 48000 - seconds
            XCTAssertEqual(skip, 0.25, accuracy: 0.03, "Start at the incoming beat, not at the unaligned file origin")
            XCTAssertLessThanOrEqual(skip, 1)
            var alignedBeats = 0
            for beat in 0..<32 {
                let sourceTime = 0.25 + Double(beat) * 0.5
                let outputTime = 12 - seconds + sourceTime - skip
                guard sourceTime >= skip, sourceTime < skip + seconds, outputTime < 11.95 else { continue }
                let outgoingBeat = (outputTime / 0.5).rounded()
                let actualBeatTime = outgoingBeat * 0.5 + 0.025 * sin(outgoingBeat * 1.7)
                XCTAssertEqual(outputTime, actualBeatTime, accuracy: 0.065,
                               "Incoming beats should meet the main attacks, not the offbeats")
                alignedBeats += 1
            }
            XCTAssertGreaterThanOrEqual(alignedBeats, 4)
            XCTAssertTrue(transfer.1.description.contains("alineada por estimación"))
            XCTAssertEqual(frames, 12 * 48000)
            XCTAssertNil(handoff.takeForEnqueue())
        }
    }
    func testAdaptivePCMAlignsBeatsAndTransfersTheIncomingDecoderAfterItsConsumedHead() async throws {
        try await withFolder { root, first, second in
            try signal(first, phase: 0.1, duration: 12.1); try signal(second, phase: 0.25, duration: 16)
            let analysis = try AudioRhythmAnalyzer.analyze(first), nextAnalysis = try AudioRhythmAnalyzer.analyze(second)
            let incoming = try NormalizedPCMDecoder(AudioDecoders.open(second)); defer { try? incoming.close() }
            var details = TrackDetails(title: "Pulso entrante", artist: "Sonora Tests", album: "Tests", duration: 16, format: "WAV", sampleRate: 48000, artwork: nil)
            details.rhythm = nextAnalysis
            let handoff = CrossfadeHandoff(); XCTAssertTrue(handoff.beginPreparation())
            handoff.supply(TransitionTrack(id: "02", prepared: PreparedTrack(decoder: incoming, details: details)))
            let decoder = CrossfadeDecoder(try NormalizedPCMDecoder(AudioDecoders.open(first)), handoff: handoff, duration: 5, adaptive: analysis)
            defer { try? decoder.close() }
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
            var samples: [Float] = []
            repeat {
                try decoder.decode(into: buffer, length: buffer.frameCapacity)
                samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            } while buffer.frameLength == buffer.frameCapacity
            let transfer = try XCTUnwrap(handoff.takeForEnqueue())
            guard case .adaptive = transfer.1 else { return XCTFail("A stable matching pair must use the adaptive PCM plan") }
            let incomingTime = Double(incoming.position) / 48000
            // Analysis may place the first candidate one sample before the
            // permitted boundary, selecting the next beat and a shorter mix.
            XCTAssertEqual(incomingTime.truncatingRemainder(dividingBy: 0.5), 0.25, accuracy: 0.035)
            XCTAssertGreaterThan(incomingTime, 4); XCTAssertLessThanOrEqual(incomingTime, 5.3)
            func peak(_ start: Double, _ end: Double) -> Float { samples[Int(start * 48000)..<Int(end * 48000)].map(abs).max() ?? 0 }
            XCTAssertGreaterThan(peak(8.095, 8.125), 0.03, "Both pulses should coincide with the outgoing beat")
            XCTAssertLessThan(peak(8.33, 8.38), 0.002, "An unaligned incoming beat must not sound between the shared beats")
            XCTAssertEqual(samples.count, Int(12.1 * 48000))
            XCTAssertNil(handoff.takeForEnqueue(), "The consumed head transfers exactly once")
        }
    }

    private final class PeakCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Float = 0
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            let value = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).map(abs).max() ?? 0
            lock.lock(); peak = max(peak, value); lock.unlock()
        }
        func value() -> Float { lock.lock(); defer { lock.unlock() }; return peak }
    }
    func testRealFolderPlayerRendersAdaptiveTransitionThroughEQAndAdvancesInOrder() async throws {
        try await withFolder { root, first, second in
            try signal(first, phase: 0.1, duration: 12.1); try signal(second, phase: 0.25, duration: 16)
            let suite = "SonoraTests.Adaptive.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
            let audio = AudioPlayer(), player = PlaybackController(defaults: defaults, audioPlayer: audio), capture = PeakCapture()
            defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
            player.equalizer.select(.flat); player.equalizer.setPreamp(-6); player.equalizer.setEnabled(true)
            player.setTransition(mode: .adaptive, duration: 5)
            audio.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
            defer { audio.mainMixerNode.removeTap(onBus: 0) }
            await player.loadFolder(root)
            player.seek(to: 7)
            let deadline = Date().addingTimeInterval(10)
            while !(player.current?.id == "02.wav" && player.isPlaying) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(player.current?.id, "02.wav"); XCTAssertTrue(player.isPlaying); XCTAssertNil(player.issue)
            guard case .adaptive = player.lastTransition else { return XCTFail("Actual folder playback must use its analyzed adaptive plan") }
            XCTAssertGreaterThan(player.currentTime, 2)
            XCTAssertGreaterThan(capture.value(), 0.03); XCTAssertLessThan(capture.value(), 0.08, "The shared EQ preamp must affect the adaptive output")
            XCTAssertEqual(player.queue.tracks.map(\.id), ["01.wav", "02.wav"])
        }
    }
}
