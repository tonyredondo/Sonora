import AVFAudio
import MediaPlayer
import SonoraCore
import XCTest
@testable import Sonora

private struct InterpretationResponseFixture: MetadataLookupTransport {
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        MetadataHTTPResponse(data: Data(#"{"explanation":"A possible reading of patience.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8),
                             status: 200, contentType: "application/json")
    }
}

final class MusicToolsIntegrationTests: XCTestCase {
    private func fixture(_ root: URL, seconds: Int = 24) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("pulse.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for frame in 0..<48000 {
            let attack = frame % 24000
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * (attack < 1200 ? 0.7 : 0.02)
            buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
        }
        for _ in 0..<seconds { try file.write(from: buffer) }
        return url
    }

    @MainActor func testAnalysisCacheMarkersAndChangedFileProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root), track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        let store = MusicToolsStore(cache: cache)
        let result = try await store.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertTrue(result.analysis.isValid)
        XCTAssertEqual(result.analysis.duration, 24, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(result.bpm), 120, accuracy: 1)
        XCTAssertGreaterThan(result.analysis.waveform.max() ?? 0, 0.6)
        let marker = SongMarker(time: 8.5, title: "Estribillo")
        let saved = try await store.save(SongAnnotations(bpm: 60, markers: [marker]), for: track, result: result)
        XCTAssertEqual(saved.bpm, 60)
        let reloaded = try await MusicToolsStore(cache: cache).load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(reloaded.annotations.markers, [marker]); XCTAssertEqual(reloaded.analysis, result.analysis)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: url.path)
        do { _ = try await store.load(track: track, folder: folder, expected: fingerprint); XCTFail("Stale file must be rejected") } catch { }
        let changedTags = try await store.load(track: track, folder: folder, expected: FileFingerprint(url))
        XCTAssertEqual(changedTags.contentID, result.contentID); XCTAssertEqual(changedTags.annotations.markers, [marker])
    }

    func testAnalysisHandlesFractionalResamplingLengths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (rate, tail) in [(44100.0, 6), (96000.0, 1)] {
            let url = root.appendingPathComponent("\(Int(rate)).wav")
            let frames = Int(rate) * 6 + tail
            try autoreleasepool {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = buffer.frameCapacity
                for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.1, count: frames) }
                try file.write(from: buffer)
            }
            let track = try XCTUnwrap(AudioTrack(relativePath: url.lastPathComponent))
            let analysis = try SongAudioAnalyzer.analyze(url: url, track: track, progress: { _ in })
            XCTAssertTrue(analysis.isValid)
            XCTAssertEqual(analysis.duration, Double(frames) / rate, accuracy: 1 / 48000)
        }
    }

    func testLyricsCacheKeysInvalidateEditedTextTimingAndLanguage() throws {
        let a = LyricsDocument(text: "[00:01]One\n[00:02]Two")
        let b = LyricsDocument(text: "[00:01]Changed\n[00:02]Two")
        let c = LyricsDocument(text: "[00:03]One\n[00:04]Two")
        XCTAssertNotEqual(LyricUnderstanding.sourceKey(a), LyricUnderstanding.sourceKey(b))
        XCTAssertNotEqual(LyricUnderstanding.sourceKey(a), LyricUnderstanding.sourceKey(c))
        XCTAssertNotEqual(LyricUnderstanding.translationKey(a, source: "auto", target: "es"), LyricUnderstanding.translationKey(a, source: "en", target: "es"))
        let invalidOffset = LyricsDocument(text: "[offset:-\(String(repeating: "9", count: 400))]\n[00:01]One")
        XCTAssertFalse(try XCTUnwrap(invalidOffset.lines.first?.time).isFinite)
        XCTAssertEqual(LyricUnderstanding.sourceKey(invalidOffset), LyricUnderstanding.sourceKey(invalidOffset))
        XCTAssertNotEqual(LyricUnderstanding.sourceKey(invalidOffset), LyricUnderstanding.sourceKey(a))
    }

    @MainActor func testOfflineInterpretationRestoresWithoutAKeychainCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Meaning.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let endpoint = "http://127.0.0.1:9"
        defaults.set(endpoint, forKey: "metadata.endpoint")
        defaults.set(true, forKey: "metadata.offline")
        let cache = MetadataLookupCache(directory: root)
        let document = LyricsDocument(text: "[00:01]A tree grows")
        let writer = LyricsInterpretationClient(connection: try MetadataProxyConnection(endpoint: endpoint, token: "fixture-only"),
                                               cache: cache, transport: InterpretationResponseFixture())
        let expected = try await writer.interpret(lyrics: "A tree grows", language: "es", offline: false)
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: cache)
        let restored = try await LyricUnderstanding.interpret(document, language: "es", settings: settings)
        XCTAssertEqual(restored, expected)
        settings.offline = false
        let cachedOnly = try await LyricUnderstanding.interpret(document, language: "es", cachedOnly: true, settings: settings)
        XCTAssertEqual(cachedOnly, expected)
    }

    @MainActor func testPlaybackClockRatePitchPauseAndSeek() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root)
        let suite = "MusicToolsTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        player.setPlaybackAdjustment(rate: 2, semitones: 3)
        player.resume()
        for _ in 0..<100 { if player.isPlaying && player.currentTime > 0.1 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(player.isPlaying)
        let start = player.currentTime
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(player.currentTime - start, 2.4, accuracy: 0.7, "Clock must use source seconds at 2x")
        // The test host also has its own paused player. Publish this controller's
        // state synchronously before inspecting the process-wide Now Playing center.
        player.setPlaybackAdjustment(rate: 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)
        player.pause(); player.seek(to: 8)
        XCTAssertEqual(player.currentTime, 8, accuracy: 0.05)
        player.setPlaybackAdjustment(rate: 0.5, semitones: -4); player.resume()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(player.currentTime, 8.75, accuracy: 0.5)
        XCTAssertEqual(player.equalizer.processor.timePitch.pitch, -400)
        player.pause()
        XCTAssertEqual(player.equalizer.playback, PlaybackAdjustment(rate: 0.5, semitones: -4))
        let data = try XCTUnwrap(defaults.data(forKey: "playbackAdjustment"))
        XCTAssertEqual(try JSONDecoder().decode(PlaybackAdjustment.self, from: data), player.equalizer.playback)
    }

    @MainActor func testRateAndPitchSurviveQueueHandoffAndFormatChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, rate, seconds) in [("01.wav", 44100.0, 4), ("02.wav", 48000.0, 12)] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(rate) {
                let value = Float(sin(Double(frame) * 2 * .pi * 440 / rate) * 0.1)
                buffer.floatChannelData![0][frame] = value; buffer.floatChannelData![1][frame] = value
            }
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
        for overlap in [false, true] {
            let suite = "MusicTools.Queue.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let player = PlaybackController(defaults: defaults)
            defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
            player.setPlaybackAdjustment(rate: 1.5, semitones: 5)
            player.setTransition(mode: overlap ? .crossfade : .continuous, duration: 1)
            await player.loadFolder(root)
            for _ in 0..<200 {
                if player.current?.id == "02.wav", player.currentTime > 0.2 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(player.current?.id, "02.wav"); XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.equalizer.processor.timePitch.rate, 1.5)
            XCTAssertEqual(player.equalizer.processor.timePitch.pitch, 500)
            let start = player.currentTime
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(player.currentTime - start, 1.2, accuracy: 0.45)
            if overlap { XCTAssertNotNil(player.lastTransition) }
            player.pause(); player.seek(to: 6)
            XCTAssertEqual(player.currentTime, 6, accuracy: 0.05)
            player.stop()
        }
    }

    /// Render the actual AVAudioUnit chain, measuring the resulting waveform rather
    /// than merely inspecting effect parameters.
    func testTimePitchProducesIndependentFrequencyAndDuration() throws {
        for setting in [PlaybackAdjustment(rate: 2), PlaybackAdjustment(semitones: 12), PlaybackAdjustment(rate: 0.5, semitones: -12)] {
            let engine = AVAudioEngine(), source = AVAudioPlayerNode(), processor = EqualizerProcessor()
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            engine.attach(source); engine.attach(processor.node); engine.attach(processor.timePitch)
            processor.applyPlayback(setting)
            let first = processor.connect(in: engine, format: format)
            engine.connect(source, to: first, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)); input.frameLength = 96000
            for frame in 0..<96000 {
                let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.5
                input.floatChannelData![0][frame] = value; input.floatChannelData![1][frame] = value
            }
            source.scheduleBuffer(input); try engine.start(); source.play()
            defer { engine.stop() }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            var samples: [Float] = []
            for _ in 0..<260 {
                let status = try engine.renderOffline(1024, to: output)
                guard status == .success else { continue }
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            let audible = samples.indices.filter { abs(samples[$0]) > 0.03 }
            let firstFrame = try XCTUnwrap(audible.first), last = try XCTUnwrap(audible.last)
            XCTAssertEqual(Double(last - firstFrame) / 48000, 2 / Double(setting.rate), accuracy: 0.25)
            let section = Array(samples[(firstFrame + 12000)..<(firstFrame + 24000)])
            let crossings = zip(section, section.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let frequency = Double(crossings) / (Double(section.count) / 48000)
            XCTAssertEqual(frequency, 440 * pow(2, Double(setting.semitones) / 12), accuracy: 12)
        }
    }
}
