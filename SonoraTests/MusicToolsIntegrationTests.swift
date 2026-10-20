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

/// Hold real decoding at a cancellable boundary to exercise overlapping clients.
private final class AnalysisGate: @unchecked Sendable {
    private let lock = NSCondition()
    private var allowed = false
    private var count = 0
    private var active = 0
    private var maximumActive = 0
    private let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var maximumConcurrentCalls: Int { lock.lock(); defer { lock.unlock() }; return maximumActive }
    func open() { lock.lock(); allowed = true; lock.broadcast(); lock.unlock() }
    func close() { lock.lock(); allowed = false; lock.unlock() }
    func analyze(_ url: URL, _ track: AudioTrack, _ progress: @Sendable (Double) -> Void) throws -> SongAnalysis {
        lock.lock(); count += 1; let call = count; active += 1; maximumActive = max(maximumActive, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while true {
            try Task.checkCancellation()
            lock.lock()
            let ready = allowed
            if !ready { _ = lock.wait(until: Date().addingTimeInterval(0.01)) }
            lock.unlock()
            if ready { break }
            guard Date() < deadline else { throw URLError(.timedOut) }
        }
        if failFirst && call == 1 { throw CocoaError(.fileReadCorruptFile) }
        return try SongAudioAnalyzer.analyze(url: url, track: track, progress: progress)
    }
}

final class MusicToolsIntegrationTests: XCTestCase {
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
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

    @MainActor func testExplicitAudioRefreshCoalescesKeepsAnnotationsAndRetainsCacheOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root), track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived")), gate = AnalysisGate()
        let store = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        gate.open()
        let original = try await store.load(track: track, folder: folder, expected: fingerprint)
        let marker = SongMarker(time: 8.5, title: "Estribillo")
        _ = try await store.save(SongAnnotations(bpm: 180, markers: [marker]), for: track, folder: folder, result: original)
        gate.close(); defer { gate.open() }
        let first = Task { try await store.load(track: track, folder: folder, expected: fingerprint, refresh: true) }
        try await waitUntil { gate.calls == 2 }
        let joined = expectation(description: "Audio refresh joined")
        let second = Task {
            try await store.load(track: track.withSource("alias"), folder: folder, expected: fingerprint, refresh: true) { _ in joined.fulfill() }
        }
        joined.assertForOverFulfill = false
        await fulfillment(of: [joined], timeout: 3)
        let displayed = try await store.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(displayed.annotations.bpm, 180)
        // Changes made during the refresh must also survive.
        _ = try await store.save(SongAnnotations(bpm: 88, markers: [marker]), for: track, folder: folder, result: original)
        first.cancel(); gate.open()
        do { _ = try await first.value; XCTFail() } catch is CancellationError { }
        let result = try await second.value
        XCTAssertEqual(gate.calls, 2); XCTAssertEqual(gate.maximumConcurrentCalls, 1)
        XCTAssertEqual(result.annotations.bpm, 88); XCTAssertEqual(result.annotations.markers, [marker])
        let failing = MusicToolsStore(cache: cache) { _, _, _ in throw CocoaError(.fileReadCorruptFile) }
        do {
            _ = try await failing.load(track: track, folder: folder, expected: fingerprint, refresh: true)
            XCTFail("A failed refresh must not be reported as a cached success")
        } catch { }
        let preserved = try await failing.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(preserved.analysis, result.analysis)
        XCTAssertEqual(preserved.annotations, result.annotations)
        XCTAssertEqual(try FileFingerprint(url), fingerprint)
    }

    @MainActor func testManualSongRefreshSurvivesSelectionChangeAndReportsIndependentFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.ManualRefresh.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for key in ["prepareQueueAudio", "prepareQueueTranslation", "prepareQueueMeaning"] { defaults.set(false, forKey: key) }
        let originalFolder = root.appendingPathComponent("original"), otherFolder = root.appendingPathComponent("other")
        let url = try fixture(originalFolder); _ = try fixture(otherFolder, seconds: 12)
        let text = "[00:01]A tree grows.\n[00:04]Spring returns."
        try text.write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        let document = LyricsDocument(text: text), fingerprint = try FileFingerprint(url)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived")), gate = AnalysisGate()
        gate.open(); defer { gate.open() }
        let tools = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        var translationCalls = 0, meaningCalls = 0, failLyrics = false
        let translations = LyricTranslationStore(cache: cache) { doc, _, _, _ in
            XCTAssertEqual(doc, document)
            translationCalls += 1
            if failLyrics { throw URLError(.cannotConnectToHost) }
            return try LyricTranslation(lines: [0: "Árbol \(translationCalls)", 1: "Vuelve la primavera."], document: doc)
        }
        let meanings = LyricInterpretationStore { doc, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            XCTAssertEqual(doc, document)
            meaningCalls += 1
            if meaningCalls > 1 { XCTAssertEqual(mode, .refresh) }
            if failLyrics { throw URLError(.cannotConnectToHost) }
            let data = try JSONSerialization.data(withJSONObject: ["explanation": "Reading \(meaningCalls)", "model": "gpt-6-astra", "effort": "xhigh"])
            return try JSONDecoder().decode(LyricsInterpretation.self, from: data)
        }
        let player = PlaybackController(defaults: defaults, musicTools: tools, lyricTranslations: translations, lyricInterpretations: meanings)
        defer { player.stop() }
        await player.loadFolder(originalFolder, autoPlay: false)
        let track = try XCTUnwrap(player.current), folder = try player.folderAccess(for: track)
        let before = try await tools.load(track: track, folder: folder, expected: fingerprint)
        let marker = SongMarker(time: 8, title: "Personal")
        _ = try await tools.save(SongAnnotations(bpm: 180, markers: [marker]), for: track, folder: folder, result: before)
        _ = try await translations.load(document, source: "auto", target: "es")
        _ = try await meanings.load(document, language: "es")
        player.seek(to: 4.25); player.setPlaybackAdjustment(rate: 1.25, semitones: 2)
        gate.close()
        player.refreshCurrentSongMetadata(); player.refreshCurrentSongMetadata()
        try await waitUntil { gate.calls == 2 }
        XCTAssertEqual(player.songMetadataRefresh?.steps[.audio], .running)
        XCTAssertEqual(player.currentTime, 4.25, accuracy: 0.05); XCTAssertFalse(player.isPlaying)
        await player.loadFolder(otherFolder, autoPlay: false)
        player.seek(to: 2.25)
        gate.open()
        try await waitUntil { player.songMetadataRefresh?.isRunning == false }
        XCTAssertEqual(player.songMetadataRefresh?.trackID, track.id)
        for step in SongMetadataRefresh.Step.allCases { XCTAssertEqual(player.songMetadataRefresh?.steps[step], .updated) }
        XCTAssertEqual(translationCalls, 2); XCTAssertEqual(meaningCalls, 2); XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(player.currentTime, 2.25, accuracy: 0.05); XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.equalizer.playback.rate, 1.25); XCTAssertEqual(player.equalizer.playback.semitones, 2)
        XCTAssertNil(player.currentSongTools, "Refreshing the previous song must not attach its analysis to the new song")
        let saved = try await tools.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(saved.annotations.bpm, 180); XCTAssertEqual(saved.annotations.markers, [marker])
        XCTAssertEqual(try FileFingerprint(url), fingerprint)

        failLyrics = true
        await player.loadFolder(originalFolder, autoPlay: false)
        player.refreshCurrentSongMetadata()
        try await waitUntil { player.songMetadataRefresh?.isRunning == false }
        XCTAssertEqual(player.songMetadataRefresh?.steps[.audio], .updated)
        guard case .failed = player.songMetadataRefresh?.steps[.translation],
              case .failed = player.songMetadataRefresh?.steps[.meaning] else {
            return XCTFail("Both independent errors must be visible")
        }
        XCTAssertEqual(translationCalls, 3); XCTAssertEqual(meaningCalls, 3)
        let preserved = try await translations.load(document, source: "auto", target: "es")
        XCTAssertEqual(preserved.lines[0], "Árbol 2")
        XCTAssertEqual(meanings.results[meanings.key(document, language: "es")]?.explanation, "Reading 2")

        await player.loadFolder(otherFolder, autoPlay: false)
        player.refreshCurrentSongMetadata()
        try await waitUntil { player.songMetadataRefresh?.isRunning == false }
        XCTAssertEqual(player.songMetadataRefresh?.steps[.audio], .updated)
        XCTAssertEqual(player.songMetadataRefresh?.steps[.translation], .skipped("Esta canción no tiene letra."))
        XCTAssertEqual(player.songMetadataRefresh?.steps[.meaning], .skipped("Esta canción no tiene letra."))
        XCTAssertEqual(translationCalls, 3); XCTAssertEqual(meaningCalls, 3)
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
        XCTAssertEqual(try XCTUnwrap(result.analysis.waveform.max()), Float(0.7 / sqrt(2)), accuracy: 0.005,
                       "A sine burst's RMS is its peak amplitude divided by sqrt(2)")
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

    @MainActor func testCachedFastTempoUsesHalfTimeWithoutDecodingOrChangingPersonalBPM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root), track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let contentID = try await AudioContentIdentity.read(track: track, folder: folder, expected: fingerprint)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        struct Identity: Encodable { let fingerprint: FileFingerprint; let contentID: String }
        struct ExistingAnalysis: Encodable {
            struct Tempo: Encodable { let bpm = 180.0; let confidence = 0.8; let variable = false }
            let duration = 24.0; let waveform: [Float] = [0.1, 0.4]; let tempo = Tempo()
        }
        try await cache.write(Identity(fingerprint: fingerprint, contentID: contentID),
                              key: "identity-v1:\(track.localID):\(url.standardizedFileURL.absoluteString)")
        try await cache.write(ExistingAnalysis(), key: "analysis:\(SongAnalysis.version):\(contentID)")
        let store = MusicToolsStore(cache: cache) { _, _, _ in
            XCTFail("Changing the tempo preference must reuse the measured audio")
            throw CocoaError(.fileReadCorruptFile)
        }
        let result = try await store.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(result.bpm, 90)
        XCTAssertEqual(result.analysis.waveform, [0.1, 0.4])
        let marker = SongMarker(time: 3.5, title: "Verse")
        let saved = try await store.save(SongAnnotations(bpm: 180, markers: [marker]), for: track, folder: folder, result: result)
        XCTAssertEqual(saved.bpm, 180, "An explicit personal tempo overrides the estimate")
        let fresh = MusicToolsStore(cache: cache)
        try await fresh.restore(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(fresh.summary(for: track, folder: folder)?.bpm, 180)
        XCTAssertEqual(fresh.summary(for: track, folder: folder)?.analysis.tempo.bpm, 90)
        XCTAssertEqual(fresh.summary(for: track, folder: folder)?.annotations.markers, [marker])
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
        try await cache.write(LegacyAnalysis(), key: "analysis:energy-v2:\(contentID)")
        let marker = SongMarker(time: 3.5, title: "Verse")
        try await cache.write(SongAnnotations(bpm: 118, markers: [marker]), key: contentID, personal: true)
        let store = MusicToolsStore(cache: cache)
        try await store.restore(track: track, folder: folder, expected: fingerprint)
        XCTAssertNil(store.summary(for: track, folder: folder), "An old analysis must not suppress the new estimate")
        let result = try await store.load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(try XCTUnwrap(result.analysis.tempo.bpm), 120, accuracy: 2)
        XCTAssertEqual(result.analysis.waveform.count, 1024, "The old peak waveform must be recomputed")
        XCTAssertEqual(result.bpm, 118, "A personal BPM correction survives reanalysis")
        XCTAssertEqual(result.annotations.markers, [marker])
        let reused = try await MusicToolsStore(cache: cache).load(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(reused.analysis, result.analysis)
        XCTAssertEqual(reused.annotations, result.annotations)
    }

    func testRMSWaveformKeepsQuietPassagesDespiteFullScaleTransientsAndHasNoFalseTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("dynamics.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            for amplitude in [0.04, 0.04, 0.2, 0.2, 0.7, 0.7, 0.12, 0.12] {
                for frame in 0..<48000 {
                    // Equally high transients throughout: peaks would erase the dynamics.
                    let value = frame % 240 == 0 ? Float(0.95) : Float(amplitude * sin(Double(frame) * 2 * .pi * 440 / 48000))
                    buffer.floatChannelData![0][frame] = value
                    buffer.floatChannelData![1][frame] = -value
                }
                try file.write(from: buffer)
            }
        }
        let result = try SongAudioAnalyzer.analyze(url: url, track: XCTUnwrap(AudioTrack(relativePath: "dynamics.wav")), progress: { _ in })
        let sections = stride(from: 0, to: 1024, by: 256).map { start in
            result.waveform[start..<(start + 256)].reduce(0, +) / 256
        }
        XCTAssertLessThan(sections[0], 0.09)
        XCTAssertGreaterThan(sections[1], sections[0] * 1.8)
        XCTAssertGreaterThan(sections[2], 0.48)
        XCTAssertLessThan(sections[3], 0.13)
        XCTAssertGreaterThan(try XCTUnwrap(result.waveform.last), 0.07, "Rounding bin sizes must not add a silent tail")
        let bars = result.waveformLevels(count: 120)
        XCTAssertLessThan(bars[0], 0.2)
        XCTAssertGreaterThan(bars[75], 0.9)
    }

    @MainActor func testOpeningPausedSongAutomaticallyAnalyzesAndSharesWorkWithTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Automatic.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root)
        let gate = AnalysisGate()
        let store = MusicToolsStore(cache: MusicToolsCache(root: root.appendingPathComponent("derived")), analyze: { try gate.analyze($0, $1, $2) })
        let player = PlaybackController(defaults: defaults, musicTools: store); defer { player.stop(); gate.open() }
        await player.loadFolder(root, autoPlay: false)
        try await waitUntil { gate.calls == 1 }
        XCTAssertNotNil(player.songAnalysisProgress)
        XCTAssertFalse(player.isPlaying)
        let track = try XCTUnwrap(player.current), fingerprint = try XCTUnwrap(player.currentDetails?.fingerprint)
        let folder = try player.folderAccess(for: track)
        let joined = expectation(description: "Tools joined automatic analysis")
        let manual = Task {
            try await store.load(track: track.withSource("alias"), folder: folder, expected: fingerprint) { _ in joined.fulfill() }
        }
        joined.assertForOverFulfill = false
        await fulfillment(of: [joined], timeout: 3)
        manual.cancel() // Dismissing tools must not cancel the player's request.
        player.seek(to: 4.25)
        gate.open()
        try await waitUntil { player.currentSongTools != nil && player.songAnalysisProgress == nil }
        do { _ = try await manual.value; XCTFail("Dismissed tools must remain cancelled") } catch is CancellationError { }
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(try XCTUnwrap(player.currentSongTools?.bpm), 120, accuracy: 1)
        XCTAssertEqual(player.currentTime, 4.25, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.songAnalysisIssue)
        player.retrySongAnalysis()
        try await waitUntil { player.songAnalysisProgress == nil }
        XCTAssertEqual(gate.calls, 1, "Reopening unchanged audio reuses its analysis")
    }

    @MainActor func testChangingSongsAndStoppingStillCompletesAndPersistsEveryAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Background.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let folders = ["first", "second", "third"].map { root.appendingPathComponent($0) }
        let urls = try folders.enumerated().map { try fixture($0.element, seconds: 8 + $0.offset * 2) }
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        let gate = AnalysisGate()
        let store = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        let player = PlaybackController(defaults: defaults, musicTools: store); defer { player.stop(); gate.open() }
        await player.loadFolder(folders[0], autoPlay: false)
        try await waitUntil { gate.calls == 1 }
        await player.loadFolder(folders[1], autoPlay: false)
        await player.loadFolder(folders[2], autoPlay: false)
        player.stop()
        XCTAssertNil(player.currentSongTools)
        XCTAssertNil(player.songAnalysisProgress)
        gate.open()
        let track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let scopes = try folders.map { try ScopedFolder($0) }
        try await waitUntil { scopes.allSatisfy { store.summary(for: track, folder: $0) != nil } }
        XCTAssertEqual(gate.calls, 3)
        XCTAssertEqual(gate.maximumConcurrentCalls, 1, "Skipping songs must not start parallel decoders")
        XCTAssertEqual(try XCTUnwrap(player.currentSongTools?.analysis.duration), 12, accuracy: 0.01,
                       "An earlier song finishing must not replace the current waveform")
        XCTAssertNil(player.songAnalysisIssue)
        XCTAssertFalse(player.isPlaying)
        let restored = MusicToolsStore(cache: cache)
        for index in folders.indices {
            try await restored.restore(track: track, folder: scopes[index], expected: FileFingerprint(urls[index]))
            XCTAssertEqual(try XCTUnwrap(restored.summary(for: track, folder: scopes[index])?.analysis.duration),
                           Double(8 + index * 2), accuracy: 0.01, "Each result must survive a new store instance")
        }
        await player.loadFolder(folders[0], autoPlay: false)
        try await waitUntil { player.songAnalysisProgress == nil }
        XCTAssertEqual(gate.calls, 3, "Returning to an earlier song must reuse its cached analysis")
    }

    @MainActor func testAutomaticTranslationFollowsAnalysisAndSurvivesSongChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Translation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let folders = ["first", "second"].map { root.appendingPathComponent($0) }
        for (index, folder) in folders.enumerated() {
            _ = try fixture(folder, seconds: 8 + index * 2)
            try "[00:01]When the rain stops \(index)\n[00:03]we will go outside.".write(
                to: folder.appendingPathComponent("pulse.lrc"), atomically: true, encoding: .utf8)
        }
        let gate = AnalysisGate()
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        let store = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        let scopes = try folders.map { try ScopedFolder($0) }
        let track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        var translated: [String] = []
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        defaults.set(false, forKey: "prepareQueueMeaning")
        let translationSettings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite),
                                                            cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
        let translations = LyricTranslationStore(cache: cache, settings: translationSettings) { document, _, target, _ in
            let index = document.lines[0].text.hasSuffix("0") ? 0 : 1
            XCTAssertNotNil(store.summary(for: track, folder: scopes[index]), "Translation must follow this song's audio analysis")
            translated.append(document.lines[0].text + ":" + target)
            return try LyricTranslation(lines: [0: "Cuando pare la lluvia", 1: "saldremos."], document: document)
        }
        let player = PlaybackController(defaults: defaults, musicTools: store, lyricTranslations: translations)
        defer { player.stop(); gate.open() }
        await player.loadFolder(folders[0], autoPlay: false)
        let firstLyrics = try XCTUnwrap(player.currentDetails?.lyrics)
        try await waitUntil { gate.calls == 1 }
        XCTAssertTrue(translated.isEmpty)
        await player.loadFolder(folders[1], autoPlay: false)
        player.stop(); gate.open()
        try await waitUntil { translated.count == 2 }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(translated, ["When the rain stops 0:es", "When the rain stops 1:es"])
        let fresh = LyricTranslationStore(cache: cache) { _, _, _, _ in XCTFail("Finished translation must be cached"); throw URLError(.unknown) }
        _ = try await fresh.load(firstLyrics, source: "auto", target: "es")
        defaults.set("fr", forKey: "lyricTranslationTarget")
        player.translationPreferencesDidChange()
        try await waitUntil { translated.count == 3 }
        XCTAssertEqual(translated.last, "When the rain stops 1:fr")
        XCTAssertEqual(gate.calls, 2, "Changing translation language must reuse the audio analysis")
    }

    @MainActor func testCancelledOnlyObserverStillCachesAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(root, seconds: 8), track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let gate = AnalysisGate(); defer { gate.open() }
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        let store = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        let observer = Task { try await store.load(track: track, folder: folder, expected: fingerprint) }
        try await waitUntil { gate.calls == 1 }
        observer.cancel()
        gate.open()
        do { _ = try await observer.value; XCTFail("The observer should cancel, without cancelling the analysis") } catch is CancellationError { }
        let restored = MusicToolsStore(cache: cache)
        try await restored.restore(track: track, folder: folder, expected: fingerprint)
        XCTAssertNotNil(restored.summary(for: track, folder: folder))
        XCTAssertEqual(gate.calls, 1)
    }

    @MainActor func testCachedSongDoesNotWaitForQueuedAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let a = try fixture(first, seconds: 8), b = try fixture(second, seconds: 10)
        let track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let firstScope = try ScopedFolder(first), secondScope = try ScopedFolder(second)
        let firstFingerprint = try FileFingerprint(a), secondFingerprint = try FileFingerprint(b)
        let cache = MusicToolsCache(root: root.appendingPathComponent("derived"))
        let gate = AnalysisGate(); gate.open(); defer { gate.open() }
        let store = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        let cached = try await store.load(track: track, folder: firstScope, expected: firstFingerprint)
        // A new instance exercises the disk cache, not just the in-memory summary.
        let fresh = MusicToolsStore(cache: cache, analyze: { try gate.analyze($0, $1, $2) })
        gate.close()
        let pending = Task { try await fresh.load(track: track, folder: secondScope, expected: secondFingerprint) }
        try await waitUntil { gate.calls == 2 }
        let reused = try await fresh.load(track: track, folder: firstScope, expected: firstFingerprint)
        XCTAssertEqual(reused.analysis, cached.analysis)
        gate.open()
        _ = try await pending.value
        XCTAssertEqual(gate.calls, 2)
    }

    @MainActor func testInvalidatingOneSourcePreservesOtherQueuedAnalyses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let a = try fixture(first, seconds: 8), b = try fixture(second, seconds: 10)
        let track = try XCTUnwrap(AudioTrack(relativePath: "pulse.wav"))
        let firstScope = try ScopedFolder(first), secondScope = try ScopedFolder(second)
        let firstFingerprint = try FileFingerprint(a), secondFingerprint = try FileFingerprint(b)
        let gate = AnalysisGate(); defer { gate.open() }
        let store = MusicToolsStore(cache: MusicToolsCache(root: root.appendingPathComponent("derived")), analyze: { try gate.analyze($0, $1, $2) })
        let invalidated = Task { try await store.load(track: track, folder: firstScope, expected: firstFingerprint) }
        try await waitUntil { gate.calls == 1 }
        let next = Task { try await store.load(track: track, folder: secondScope, expected: secondFingerprint) }
        store.invalidate(at: first)
        gate.open()
        do { _ = try await invalidated.value; XCTFail("File mutation must cancel reads of the old source") } catch is CancellationError { }
        let result = try await next.value
        XCTAssertEqual(result.analysis.duration, 10, accuracy: 0.01)
        XCTAssertNil(store.summary(for: track, folder: firstScope))
        XCTAssertNotNil(store.summary(for: track, folder: secondScope))
        _ = try await store.load(track: track, folder: firstScope, expected: firstFingerprint)
        XCTAssertEqual(gate.calls, 3, "Invalidating one source must not stall the queue or poison later requests")
        XCTAssertEqual(gate.maximumConcurrentCalls, 1)
    }

    @MainActor func testAutomaticAnalysisFailureIsVisibleAndCanRetryWithoutInterruptingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MusicTools.Retry.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, seconds: 8)
        let gate = AnalysisGate(failFirst: true); gate.open()
        let store = MusicToolsStore(cache: MusicToolsCache(root: root.appendingPathComponent("derived")), analyze: { try gate.analyze($0, $1, $2) })
        let player = PlaybackController(defaults: defaults, musicTools: store); defer { player.stop() }
        await player.loadFolder(root)
        try await waitUntil { player.songAnalysisIssue != nil && player.isPlaying }
        XCTAssertNil(player.songAnalysisProgress)
        XCTAssertNil(player.currentSongTools)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.calls, 1, "A failed analysis must not loop on playback ticks")
        let position = player.currentTime
        player.retrySongAnalysis()
        try await waitUntil { player.currentSongTools != nil && player.songAnalysisProgress == nil }
        XCTAssertNil(player.songAnalysisIssue)
        XCTAssertEqual(gate.calls, 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.currentTime, position)
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

    @MainActor func testInterpretationCacheReadsDoNotGenerateAndLanguagesStaySeparate() async throws {
        let document = LyricsDocument(text: "A tree grows")
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"A possible reading.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
        var requests: [String] = [], cachedLanguages: Set<String> = [], fail = false
        let store = LyricInterpretationStore { _, language, cachedOnly in
            if cachedOnly == .cachedOnly {
                guard cachedLanguages.contains(language) else { throw MetadataLookupError.notCached }
            } else {
                requests.append(language)
                if fail { throw URLError(.cannotConnectToHost) }
            }
            return value
        }
        await store.restore(document, language: "es")
        XCTAssertTrue(requests.isEmpty)
        _ = try await store.load(document, language: "es")
        XCTAssertEqual(requests, ["es"])
        await store.restore(document, language: "en")
        XCTAssertNil(store.results[store.key(document, language: "en")])
        _ = try await store.load(document, language: "es")
        XCTAssertEqual(requests, ["es"], "Reopening a completed interpretation must reuse its result")
        cachedLanguages.insert("fr")
        await store.restore(document, language: "fr")
        XCTAssertEqual(store.results[store.key(document, language: "fr")], value)
        fail = true
        do { _ = try await store.load(document, language: "en"); XCTFail() } catch { }
        XCTAssertNotNil(store.automaticIssue)
        await store.restore(document, language: "de")
        XCTAssertNil(store.statuses[store.key(document, language: "de")])
        XCTAssertEqual(requests, ["es", "en"])
        fail = false
        _ = try await store.load(document, language: "en")
        XCTAssertEqual(requests, ["es", "en", "en"])
    }

    @MainActor func testCancelledInterpretationObserverKeepsResultWithoutReplacingAnotherLanguage() async throws {
        let document = LyricsDocument(text: "A tree grows")
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"Old language.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
        var pending: CheckedContinuation<LyricsInterpretation, Never>?
        let store = LyricInterpretationStore { _, _, cachedOnly in
            if cachedOnly == .cachedOnly { throw MetadataLookupError.notCached }
            return await withCheckedContinuation { pending = $0 }
        }
        let task = Task { try await store.load(document, language: "es") }
        try await waitUntil { pending != nil }
        let completion = try XCTUnwrap(pending)
        XCTAssertEqual(store.statuses[store.key(document, language: "es")], .interpreting)
        task.cancel()
        await store.restore(document, language: "en")
        completion.resume(returning: value)
        do { _ = try await task.value; XCTFail("The dismissed observer stays cancelled") } catch is CancellationError { }
        XCTAssertEqual(store.results[store.key(document, language: "es")], value)
        XCTAssertNil(store.results[store.key(document, language: "en")])
        XCTAssertNil(store.statuses[store.key(document, language: "en")])
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
