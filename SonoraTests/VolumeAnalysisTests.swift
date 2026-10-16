import AVFAudio
import CryptoKit
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class VolumeAnalysisTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func tone(_ url: URL, amplitude: Float, duration: Double = 3, rate: Double = 48000) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int(rate * duration), position = 0
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, Int(buffer.frameCapacity)))
            for frame in 0..<Int(buffer.frameLength) {
                let value = amplitude * Float(sin(2 * .pi * 1000 * Double(position + frame) / rate))
                for channel in 0..<2 { buffer.floatChannelData![channel][frame] = value }
            }
            try file.write(from: buffer); remaining -= Int(buffer.frameLength); position += Int(buffer.frameLength)
        }
    }
    private func target(_ name: String, root: URL, folder: ScopedFolder) -> VolumeAnalysisTarget {
        VolumeAnalysisTarget(id: name, url: root.appendingPathComponent(name), folder: folder)
    }

    func testFullDecodeMeasuresTrackAndAlbumWithoutChangingFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try tone(root.appendingPathComponent("loud.wav"), amplitude: 0.1)
        try tone(root.appendingPathComponent("soft.wav"), amplitude: 0.05)
        let folder = try ScopedFolder(root)
        let targets = [target("loud.wav", root: root, folder: folder), target("soft.wav", root: root, folder: folder)]
        let before = try targets.map { SHA256.hash(data: try Data(contentsOf: $0.url)) }
        let result = try await VolumeAnalysisService.analyze(targets, album: true)
        let loud = try XCTUnwrap(result.records["loud.wav"]), soft = try XCTUnwrap(result.records["soft.wav"])
        XCTAssertEqual(loud.gain, 2.0, accuracy: 0.08, "A 1 kHz stereo sine at -20 dBFS is approximately -20 LUFS")
        XCTAssertEqual(soft.gain - loud.gain, 6.0206, accuracy: 0.02)
        XCTAssertEqual(loud.peak, 0.1, accuracy: 0.0001); XCTAssertEqual(soft.peak, 0.05, accuracy: 0.0001)
        let album = try XCTUnwrap(result.album)
        XCTAssertEqual(album.gain - loud.gain, 2.0412, accuracy: 0.04, "Album loudness combines power, not an average of dB gains")
        XCTAssertEqual(album.peak, 0.1, accuracy: 0.0001)
        XCTAssertEqual(Set(album.members.keys), Set(targets.map(\.id)))
        XCTAssertEqual(try targets.map { SHA256.hash(data: try Data(contentsOf: $0.url)) }, before)
    }

    func testAnalyzerUsesAllTwelvePlaybackFormatPaths() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        for name in ["volume.wav", "volume.flac", "volume.mp3", "volume.m4a", "volume.alac.m4a", "volume.aiff", "extra.ogg", "extra.opus", "extra.wv", "extra.tta", "extra.caf", "extra.aac"] {
            let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension))
            try FileManager.default.copyItem(at: resource, to: root.appendingPathComponent(name))
            do {
                let result = try await VolumeAnalysisService.analyze([target(name, root: root, folder: folder)], album: false)
                let measured = try XCTUnwrap(result.records[name], name)
                XCTAssertTrue(measured.gain.isFinite, name); XCTAssertGreaterThan(measured.peak, 0.01, name)
            } catch { XCTFail("\(name): \(error)") }
        }
    }

    func testQuarterSecondClipsCannotProduceAnIntegratedLoudness() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("short.flac"))
        do {
            _ = try await VolumeAnalysisService.analyze([target("short.flac", root: root, folder: try ScopedFolder(root))], album: false)
            XCTFail("BS.1770 integrated loudness needs at least a 400 ms gating block")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testLocalResultsPersistAndAnyChangedAlbumMemberInvalidatesAlbumGain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.wav", "b.wav"] { try tone(root.appendingPathComponent(name), amplitude: 0.1) }
        let folder = try ScopedFolder(root), targets = [target("a.wav", root: root, folder: folder), target("b.wav", root: root, folder: folder)]
        let suite = "SonoraTests.Volume.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let batch = try await VolumeAnalysisService.analyze(targets, album: true)
        let store = VolumeAnalysisStore(defaults: defaults); try store.record(batch)
        let restored = VolumeAnalysisStore(defaults: defaults)
        XCTAssertEqual(restored.records, store.records); XCTAssertEqual(restored.albums, store.albums)
        let a = try XCTUnwrap(restored.candidate(for: "a.wav", members: targets))
        let originalA = try FileFingerprint(targets[0].url)
        XCTAssertNotNil(a.validated(fingerprint: originalA)?.albumGain)
        try tone(targets[1].url, amplitude: 0.02, duration: 4)
        XCTAssertNotNil(a.validated(fingerprint: originalA)?.trackGain)
        XCTAssertNil(a.validated(fingerprint: originalA)?.albumGain)
        let b = try XCTUnwrap(restored.candidate(for: "b.wav", members: targets))
        XCTAssertNil(b.validated(fingerprint: try FileFingerprint(targets[1].url)))
    }

    func testCorruptSavedAnalysisCannotBeSilentlyOverwritten() throws {
        let suite = "SonoraTests.VolumeCorrupt.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("broken".utf8); defaults.set(corrupt, forKey: "volumeAnalysis")
        let store = VolumeAnalysisStore(defaults: defaults)
        XCTAssertNotNil(store.issue)
        XCTAssertThrowsError(try store.record(VolumeAnalysisBatch(records: [:], album: nil)))
        XCTAssertEqual(defaults.data(forKey: "volumeAnalysis"), corrupt)
        store.reset(); XCTAssertNil(store.issue)
        XCTAssertNil(VolumeAnalysisStore(defaults: defaults).issue)
    }

    func testInvalidAlbumBatchDoesNotPartiallyMutateSavedOrInMemoryResults() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("song.wav"); try tone(url, amplitude: 0.1)
        let suite = "SonoraTests.VolumeAtomic.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VolumeAnalysisStore(defaults: defaults)
        let measured = try await VolumeAnalysisService.analyze([.init(id: "song", url: url, folder: ScopedFolder(root))], album: false)
        try store.record(measured)
        let saved = defaults.data(forKey: "volumeAnalysis"), before = store.records
        let invalid = VolumeAlbumMeasurement(id: "bad", members: ["missing": try FileFingerprint(url)], gain: -6, peak: 0.5)
        let extra = try XCTUnwrap(measured.records["song"])
        XCTAssertThrowsError(try store.record(.init(records: ["new": extra], album: invalid)))
        XCTAssertEqual(store.records, before); XCTAssertEqual(defaults.data(forKey: "volumeAnalysis"), saved)
    }

    func testSilenceAndEscapingSymlinkProduceErrorsWithoutResults() async throws {
        let root = try root(), outside = try self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try tone(root.appendingPathComponent("silence.wav"), amplitude: 0)
        try tone(outside.appendingPathComponent("other.wav"), amplitude: 0.1)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.wav"), withDestinationURL: outside.appendingPathComponent("other.wav"))
        let folder = try ScopedFolder(root)
        for name in ["silence.wav", "escape.wav"] {
            do { _ = try await VolumeAnalysisService.analyze([target(name, root: root, folder: folder)], album: false); XCTFail("Must reject \(name)") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        private var task: Task<VolumeAnalysisBatch, Error>?
        func set(_ value: Task<VolumeAnalysisBatch, Error>) { lock.lock(); task = value; lock.unlock() }
        func cancel() { lock.lock(); let value = task; lock.unlock(); value?.cancel() }
    }
    func testCancellationDuringDecodeDiscardsTheIncompleteMeasurement() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try tone(root.appendingPathComponent("long.wav"), amplitude: 0.1, duration: 30)
        let item = target("long.wav", root: root, folder: try ScopedFolder(root)), cancellation = Cancellation()
        let task = Task {
            try await VolumeAnalysisService.analyze([item], album: false) { value in
                if value.fraction > 0.05 { cancellation.cancel() }
            }
        }
        cancellation.set(task)
        do { _ = try await task.value; XCTFail("An incomplete analysis must not be published") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testStreamingMeterUsesMonoAndSurroundChannelWeightsAndRejectsUnknownLayouts() throws {
        func measure(_ format: AVAudioFormat, lfe: Bool = false) throws -> VolumeLoudnessMeter {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let amplitude = channel < 2 ? 0.1 : (lfe && channel == 3 ? 0.8 : 0)
                    buffer.floatChannelData![channel][frame] = Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
                }
            }
            let meter = try VolumeLoudnessMeter(format: format); try meter.append(buffer); return meter
        }
        let stereo = try measure(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
        let mono = try measure(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
        XCTAssertEqual(try mono.gain().doubleValue - stereo.gain().doubleValue, 3.0103, accuracy: 0.02)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
        let surround = try measure(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout), lfe: true)
        XCTAssertEqual(try surround.gain().doubleValue, try stereo.gain().doubleValue, accuracy: 0.02, "LFE is excluded from loudness weighting")
        XCTAssertEqual(surround.peak, 0.8, accuracy: 0.0001, "Peak measurement still includes LFE")
        let unknown = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        XCTAssertThrowsError(try VolumeLoudnessMeter(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: unknown)))
    }
}
