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
        let scoped = track.withSource("library-source")
        let saved = try await store.save(SongAnnotations(bpm: 60, markers: [marker]), for: scoped, folder: folder, result: result)
        XCTAssertEqual(saved.bpm, 60)
        XCTAssertEqual(store.summary(for: track, folder: folder)?.annotations.markers, [marker])
        XCTAssertEqual(store.summary(for: scoped, folder: folder)?.annotations.markers, [marker])
        let restored = MusicToolsStore(cache: cache)
        try await restored.restore(track: scoped, folder: folder, expected: fingerprint)
        XCTAssertEqual(restored.summary(for: track, folder: folder)?.analysis, result.analysis)
        let otherRoot = root.appendingPathComponent("different-source")
        _ = try fixture(otherRoot)
        XCTAssertNil(restored.summary(for: track, folder: try ScopedFolder(otherRoot)), "Same filename in another folder is not the same file")
        let reloaded = try await MusicToolsStore(cache: cache).load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(reloaded.annotations.markers, [marker]); XCTAssertEqual(reloaded.analysis, result.analysis)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: url.path)
        do { _ = try await store.load(track: track, folder: folder, expected: fingerprint); XCTFail("Stale file must be rejected") } catch { }
        let changedTags = try await store.load(track: track, folder: folder, expected: FileFingerprint(url))
        XCTAssertEqual(changedTags.contentID, result.contentID); XCTAssertEqual(changedTags.annotations.markers, [marker])
    }

    @MainActor func testMusicalTempoReplacesOldAnalysisAndPreservesPersonalAnnotations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var energy = [Double](repeating: 0.02, count: 2000)
        for beat in 0..<40 {
            for (fraction, amplitude) in [(0.0, 0.4), (0.5, 0.22), (0.75, 0.11)] {
                let time = Double(beat) * 0.5 + fraction * 0.5 + 0.025 * sin(Double(beat) * 1.7)
                let center = Int(time * 100)
                for i in max(0, center - 4)...min(1999, center + 4) {
                    energy[i] += amplitude * (0.8 + 0.2 * cos(Double(beat))) * exp(-pow((Double(i) / 100 - time) / 0.018, 2))
                }
            }
        }
        let url = root.appendingPathComponent("musical.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            for second in 0..<20 {
                for frame in 0..<48000 {
                    let value = Float(energy[second * 100 + frame / 480] * sin(Double(frame) * 2 * .pi * 440 / 48000))
                    buffer.floatChannelData![0][frame] = value
                    buffer.floatChannelData![1][frame] = value
                }
                try file.write(from: buffer)
            }
        }
        let track = try XCTUnwrap(AudioTrack(relativePath: "musical.wav")), folder = try ScopedFolder(root)
        let fingerprint = try FileFingerprint(url)
        let contentID = try await AudioContentIdentity.read(track: track, folder: folder, expected: fingerprint)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        struct LegacyIdentity: Encodable { let fingerprint: FileFingerprint; let contentID: String }
        try await cache.write(LegacyIdentity(fingerprint: fingerprint, contentID: contentID),
                              key: "identity-v1:\(track.localID):\(url.standardizedFileURL.absoluteString)")
        struct LegacyAnalysis: Encodable {
            struct Tempo: Encodable { let bpm: Double? = nil; let confidence = 0.0; let variable = true }
            let duration = 20.0; let waveform: [Float] = [0.4]; let tempo = Tempo()
        }
        try await cache.write(LegacyAnalysis(), key: "analysis:energy-v1:\(contentID)")
        let marker = SongMarker(time: 3.5, title: "Verse")
        try await cache.write(SongAnnotations(bpm: 118, markers: [marker]), key: contentID, personal: true)
        let store = MusicToolsStore(cache: cache)
        try await store.restore(track: track, folder: folder, expected: fingerprint)
        XCTAssertNil(store.summary(for: track, folder: folder), "An old analysis must not suppress the new estimate")
        let result = try await store.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(try XCTUnwrap(result.analysis.tempo.bpm), 120, accuracy: 2)
        XCTAssertEqual(result.bpm, 118, "A personal BPM correction survives reanalysis")
        XCTAssertEqual(result.annotations.markers, [marker])
        let reused = try await MusicToolsStore(cache: cache).load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(reused.analysis, result.analysis)
        XCTAssertEqual(reused.annotations, result.annotations)
    }

    @MainActor func testLibraryAndQueueAliasesSharePlaybackAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Alias.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, seconds: 8)
        let store = MusicToolsStore(cache: MusicToolsCache(root: root.appendingPathComponent("derived")))
        let player = PlaybackController(defaults: defaults, musicTools: store); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        let queued = try XCTUnwrap(player.current)
        let source = try XCTUnwrap(player.libraryID(for: queued)?.split(separator: "\0").first).description
        let scoped = queued.withSource(source)
        XCTAssertNotEqual(scoped.id, queued.id)
        XCTAssertTrue(player.isEditingTrackCurrent(scoped))
        player.seek(to: 4.25)
        XCTAssertEqual(player.currentTime, 4.25, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        let snapshot = try await player.readMetadata(for: scoped)
        let result = try await player.musicTools.load(track: scoped, folder: player.folderAccess(for: scoped), expected: snapshot.fingerprint)
        XCTAssertEqual(player.currentSongTools?.analysis, result.analysis, "Analysis opened from the library must appear in the unscoped queue player")
        let marker = SongMarker(time: player.currentTime, title: "Current phrase")
        _ = try await player.musicTools.save(SongAnnotations(markers: [marker]), for: scoped, folder: player.folderAccess(for: scoped), result: result)
        XCTAssertEqual(player.currentSongTools?.annotations.markers, [marker])
        XCTAssertFalse(player.isPlaying, "Opening tools and saving annotations must keep paused playback paused")
    }

    @MainActor func testAnalysisKeepsCueSegmentsAndAnnotationsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root), folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let sheet = """
        FILE "pulse.wav" WAVE
        TRACK 01 AUDIO
        INDEX 01 00:00:00
        TRACK 02 AUDIO
        INDEX 01 00:08:00
        """
        let tracks = try CueSheet.tracks(data: Data(sheet.utf8), sheetPath: "pulse.cue", availablePaths: ["pulse.wav"])
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived")), store = MusicToolsStore(cache: cache)
        let first = try await store.load(track: tracks[0], folder: folder, expected: fingerprint)
        let second = try await store.load(track: tracks[1], folder: folder, expected: fingerprint)
        XCTAssertEqual(first.analysis.duration, 8, accuracy: 0.001)
        XCTAssertEqual(second.analysis.duration, 16, accuracy: 0.001)
        XCTAssertNotEqual(first.contentID, second.contentID, "Virtual tracks must hash their own audio interval")
        let marker = SongMarker(time: 1.25, title: "Inside second track")
        _ = try await store.save(SongAnnotations(bpm: 90, markers: [marker]), for: tracks[1], folder: folder, result: second)
        XCTAssertTrue(store.summary(for: tracks[0], folder: folder)?.annotations.markers.isEmpty == true)
        let restored = MusicToolsStore(cache: cache)
        for track in tracks { try await restored.restore(track: track.withSource("library"), folder: folder, expected: fingerprint) }
        XCTAssertTrue(restored.summary(for: tracks[0], folder: folder)?.annotations.markers.isEmpty == true)
        XCTAssertEqual(restored.summary(for: tracks[1], folder: folder)?.annotations.markers, [marker])
        XCTAssertEqual(restored.summary(for: tracks[1], folder: folder)?.bpm, 90)
    }

    @MainActor func testInterpretationRequiresANewRequestForEachLanguageAndRetry() async throws {
        let model = LyricInterpretationModel(), document = LyricsDocument(text: "A tree grows")
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"A possible reading.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
        var requests: [String] = [], cachedLanguages: Set<String> = [], fail = false
        let interpret: @MainActor (LyricsDocument, String, Bool) async throws -> LyricsInterpretation = { _, language, cachedOnly in
            if cachedOnly {
                guard cachedLanguages.contains(language) else { throw URLError(.resourceUnavailable) }
            } else {
                requests.append(language)
                if fail { throw URLError(.cannotConnectToHost) }
            }
            return value
        }
        await model.load(document, language: "es", request: nil, interpret: interpret)
        XCTAssertTrue(requests.isEmpty)
        let request = LyricInterpretationModel.Request(language: "es")
        await model.load(document, language: "es", request: request, interpret: interpret)
        XCTAssertEqual(requests, ["es"]); XCTAssertEqual(model.explanation, value.explanation)
        await model.load(document, language: "en", request: request, interpret: interpret)
        XCTAssertNil(model.explanation)
        await model.load(document, language: "es", request: request, interpret: interpret)
        XCTAssertEqual(requests, ["es"], "Changing language and returning must not reuse a consumed button press")
        cachedLanguages.insert("fr")
        await model.load(document, language: "fr", request: request, interpret: interpret)
        XCTAssertEqual(model.explanation, value.explanation); XCTAssertEqual(requests, ["es"])
        fail = true
        let failedRequest = LyricInterpretationModel.Request(language: "en")
        await model.load(document, language: "en", request: failedRequest, interpret: interpret)
        XCTAssertNotNil(model.issue); XCTAssertFalse(model.running)
        await model.load(document, language: "de", request: failedRequest, interpret: interpret)
        XCTAssertNil(model.issue); XCTAssertEqual(requests, ["es", "en"])
        fail = false
        await model.load(document, language: "en", request: .init(language: "en"), interpret: interpret)
        XCTAssertEqual(requests, ["es", "en", "en"]); XCTAssertEqual(model.explanation, value.explanation)
    }

    @MainActor func testCancelledInterpretationCannotReplaceAnotherLanguage() async throws {
        let model = LyricInterpretationModel(), document = LyricsDocument(text: "A tree grows")
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"Old language.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
        var pending: CheckedContinuation<LyricsInterpretation, Never>?
        let task = Task { @MainActor in
            await model.load(document, language: "es", request: .init(language: "es")) { _, _, cachedOnly in
                if cachedOnly { throw URLError(.resourceUnavailable) }
                return await withCheckedContinuation { pending = $0 }
            }
        }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard let completion = pending else { task.cancel(); return XCTFail("Generation did not start") }
        XCTAssertTrue(model.running)
        task.cancel()
        await model.load(document, language: "en", request: nil) { _, _, _ in throw URLError(.resourceUnavailable) }
        completion.resume(returning: value)
        await task.value
        XCTAssertNil(model.explanation); XCTAssertNil(model.issue); XCTAssertFalse(model.running)
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
