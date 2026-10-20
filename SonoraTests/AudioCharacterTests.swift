import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class AudioCharacterTests: XCTestCase {
    private func result() throws -> AudioCharacter {
        try JSONDecoder().decode(AudioCharacter.self, from: Data(#"{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Alternative Rock","score":0.3},{"label":"Rock---Indie Rock","score":0.2}],"moods":{"happy":0.2,"sad":0.8,"relaxed":0.9,"aggressive":0.1}}"#.utf8))
    }
    private func wait(_ check: () -> Bool) async throws {
        for _ in 0..<100 where !check() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(check())
    }
    func testCoalescesAndPersistsAcrossFoldersAndFailedRefreshKeepsPreviousTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CharacterTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
        let file = root.appendingPathComponent("sample.wav"); try Data([1,2,3]).write(to: file)
        let track = try XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder = try ScopedFolder(root), fingerprint = try FileFingerprint(file)
        let cache = MusicToolsCache(root: root.appendingPathComponent("cache")), expected = try result()
        let analysis = SongAnalysis(duration: 3, waveform: [0.1], tempo: TempoEstimate(bpm: nil, confidence: 0, variable: false))
        let prepared = SongToolsResult(contentID: "same-pcm", fingerprint: fingerprint, analysis: analysis, annotations: SongAnnotations())
        var calls = 0, fail = false
        var continuation: CheckedContinuation<AudioCharacter, Error>?
        let store = AudioCharacterStore(settings: settings, cache: cache) { _, _, _, _ in
            calls += 1
            if fail { throw URLError(.cannotConnectToHost) }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let a = Task { try await store.load(track: track, folder: folder, expected: fingerprint, preparedAudio: prepared) }
        try await wait { continuation != nil }
        let b = Task { try await store.load(track: track, folder: folder, expected: fingerprint, preparedAudio: prepared) }
        await Task.yield(); continuation?.resume(returning: expected); continuation = nil
        let first = try await a.value, joined = try await b.value
        XCTAssertEqual(first, joined); XCTAssertEqual(calls, 1)
        fail = true
        do { _ = try await store.load(track: track, folder: folder, expected: fingerprint, preparedAudio: prepared, refresh: true); XCTFail("Refresh must fail") } catch { }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.summary(track, folder: folder, expected: fingerprint), expected)
        settings.offline = true
        let reopened = AudioCharacterStore(settings: settings, cache: cache) { _, _, _, _ in XCTFail("Cache must avoid another model call"); return expected }
        let restored = try await reopened.load(track: track, folder: folder, expected: fingerprint, cachedOnly: true)
        XCTAssertEqual(restored, expected)
        try FileManager.default.copyItem(at: file, to: root.appendingPathComponent("copy.wav"))
        let copy = try XCTUnwrap(AudioTrack(relativePath: "copy.wav"))
        let copyFingerprint = try FileFingerprint(root.appendingPathComponent("copy.wav"))
        let preparedCopy = SongToolsResult(contentID: "same-pcm", fingerprint: copyFingerprint, analysis: analysis, annotations: SongAnnotations())
        let reused = try await reopened.load(track: copy, folder: folder, expected: copyFingerprint, preparedAudio: preparedCopy, cachedOnly: true)
        XCTAssertEqual(reused, expected)
    }
    func testChangedAudioNeverReusesAnOldBPMIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CharacterTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
        let url = root.appendingPathComponent("changed.wav")
        func write(_ level: Float, frames: AVAudioFrameCount) throws {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)); buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = level }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        }
        try write(0.1, frames: 32000)
        let track = try XCTUnwrap(AudioTrack(relativePath: "changed.wav")), folder = try ScopedFolder(root), oldFingerprint = try FileFingerprint(url)
        let identity = try await AudioContentIdentity.read(track: track, folder: folder, expected: oldFingerprint)
        let prepared = SongToolsResult(contentID: identity, fingerprint: oldFingerprint,
                                      analysis: SongAnalysis(duration: 2, waveform: [0.1], tempo: TempoEstimate(bpm: nil, confidence: 0, variable: false)), annotations: SongAnnotations())
        var calls = 0
        let value = try result(), store = AudioCharacterStore(settings: settings, cache: MusicToolsCache(root: root.appendingPathComponent("cache"))) { _, _, _, _ in calls += 1; return value }
        _ = try await store.load(track: track, folder: folder, expected: oldFingerprint, preparedAudio: prepared)
        try write(0.3, frames: 32001)
        let changed = try FileFingerprint(url)
        XCTAssertNotEqual(changed, oldFingerprint)
        _ = try await store.load(track: track, folder: folder, expected: changed, preparedAudio: prepared)
        XCTAssertEqual(calls, 2, "A stale BPM snapshot must not alias changed audio to the previous style cache")
    }
    func testSampledUploadUsesSeparatedRegionsAndNeverChangesTheSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("regions.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        audio.frameLength = 16000
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        for second in 0..<120 {
            for frame in 0..<16000 { audio.floatChannelData![0][frame] = Float(second) / 240 }
            try file?.write(from: audio)
        }
        file = nil
        let before = try Data(contentsOf: url), track = try XCTUnwrap(AudioTrack(relativePath: "regions.wav"))
        let data = try await AudioCharacterPreparation.prepare(track: track, folder: ScopedFolder(root), expected: FileFingerprint(url))
        XCTAssertEqual(data.count, 2_880_044)
        func sample(_ second: Int) -> Double {
            let offset = 44 + second * 32000 + 16000
            return Double(data.withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)) }) / 32768
        }
        XCTAssertEqual(sample(0), 14.0 / 240, accuracy: 0.01)
        XCTAssertEqual(sample(30), 45.0 / 240, accuracy: 0.01)
        XCTAssertEqual(sample(60), 77.0 / 240, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let fingerprint = try FileFingerprint(url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)], ofItemAtPath: url.path)
        do { _ = try await AudioCharacterPreparation.prepare(track: track, folder: ScopedFolder(root), expected: fingerprint); XCTFail("Reject changed input") }
        catch { XCTAssertEqual(error.localizedDescription, MetadataIOError.changed.localizedDescription) }
    }
}
