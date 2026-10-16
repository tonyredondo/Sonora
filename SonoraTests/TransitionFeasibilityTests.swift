import AVFAudio
import SFBAudioEngine
import XCTest
@testable import Sonora

/// Bounded engine experiments. These do not expose a crossfade or EQ product mode.
@MainActor
final class TransitionFeasibilityTests: XCTestCase {
    private let rate = 44100.0
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Float] = []
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            lock.lock(); defer { lock.unlock() }
            if values.count < 100000 { values.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) }
        }
        func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private func writeSignal(_ url: URL, value: Float, sampleRate: Double = 44100, channels: AVAudioChannelCount = 2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 4))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            buffer.floatChannelData![channel].initialize(repeating: value, count: Int(buffer.frameLength))
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
    private func render(_ engine: AVAudioEngine, count: Int) async throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var samples: [Float] = []
        for _ in 0..<count {
            let status = try engine.renderOffline(512, to: buffer)
            if status == .success { samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
            else if status == .error { XCTFail("Offline audio render failed"); break }
            // Yield to the real decoder worker; this test measures samples, not CPU speed.
            try await Task.sleep(for: .milliseconds(2))
        }
        return samples
    }
    func testFolderPlayerJoinContainsNoInsertedSamplesForMatchingFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("01.wav"), second = root.appendingPathComponent("02.wav")
        try writeSignal(first, value: 0.2); try writeSignal(second, value: 0.4)
        let player = AudioPlayer()
        let controller = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!, audioPlayer: player)
        defer { controller.stop() }
        let capture = Capture()
        player.sourceNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { player.sourceNode.removeTap(onBus: 0) }
        await controller.loadFolder(root)
        XCTAssertNil(controller.issue)
        try await Task.sleep(for: .milliseconds(1200))
        let samples = capture.snapshot()
        let start = try XCTUnwrap(samples.firstIndex { $0 > 0.15 })
        let framesPerTrack = Int(rate / 4)
        XCTAssertGreaterThanOrEqual(samples.count - start, framesPerTrack * 2)
        guard samples.count - start >= framesPerTrack * 2 else { return }
        let firstError = samples[start..<(start + framesPerTrack)].map { abs($0 - 0.2) }.max()!
        let secondError = samples[(start + framesPerTrack)..<(start + framesPerTrack * 2)].map { abs($0 - 0.4) }.max()!
        XCTAssertLessThan(firstError, 0.0001)
        XCTAssertLessThan(secondError, 0.0001)
        print("GAPLESS: real folder controller verified \(framesPerTrack * 2) contiguous PCM frames, 44.1 kHz stereo; max error \(max(firstError, secondError))")
    }
    func testTwoDecodedStreamsCanOverlapThroughTenBandEQ() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("A.wav"), root.appendingPathComponent("B.wav")]
        try writeSignal(urls[0], value: 0.2)
        try writeSignal(urls[1], value: 0.2, sampleRate: 48000, channels: 1)
        let buffers = try urls.enumerated().map { index, url -> AVAudioPCMBuffer in
            let decoder = try AudioDecoders.open(url)
            defer { try? decoder.close() }
            let source = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: AVAudioFrameCount(decoder.length))!
            try decoder.decode(into: source, length: source.frameCapacity)
            let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let converter = AVAudioConverter(from: source.format, to: target)!
            converter.primeMethod = .none
            let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * rate / source.format.sampleRate)) + 64
            let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            if let conversionError { throw conversionError }
            XCTAssertNotEqual(status, .error)
            XCTAssertGreaterThan(buffer.frameLength, 10000)
            // Equal-power fades are computed on decoded PCM, without touching files.
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let progress = Double(frame) / Double(buffer.frameLength - 1)
                    let gain = index == 0 ? cos(progress * .pi / 2) : sin(progress * .pi / 2)
                    buffer.floatChannelData![channel][frame] *= Float(gain)
                }
            }
            return buffer
        }
        let engine = AVAudioEngine(), mix = AVAudioMixerNode(), eq = AVAudioUnitEQ(numberOfBands: 10)
        let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        engine.attach(mix); engine.attach(eq)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        for index in nodes.indices {
            engine.attach(nodes[index]); engine.connect(nodes[index], to: mix, fromBus: 0, toBus: AVAudioNodeBus(index), format: buffers[index].format)
            nodes[index].scheduleBuffer(buffers[index], completionHandler: nil)
        }
        for (band, frequency) in zip(eq.bands, [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]) {
            band.frequency = Float(frequency); band.filterType = .parametric; band.bandwidth = 1; band.gain = 0; band.bypass = false
        }
        engine.connect(mix, to: eq, format: format); engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start(); defer { engine.stop() }
        for node in nodes { node.play() }
        let samples = try await render(engine, count: 28)
        let interior = Array(samples[512..<10000])
        XCTAssertGreaterThan(interior.min() ?? 0, 0.19)
        XCTAssertLessThan(interior.max() ?? 1, 0.3)
        XCTAssertEqual(eq.bands.count, 10)
        print("OVERLAP: 44.1 kHz stereo + 48 kHz mono through 10-band EQ; peak \(interior.max() ?? 0)")
    }
}
