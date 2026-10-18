import AVFAudio
import CryptoKit
import SonoraCore
import XCTest
@testable import Sonora

final class LyricsAudioPreparationTests: XCTestCase {
    private func fixture(frames: AVAudioFrameCount = 88200) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.2 * sin(Float(frame) * 0.03) } }
        try AVAudioFile(forWriting: root.appendingPathComponent("sample.wav"), settings: format.settings).write(from: buffer)
        return root
    }
    func testExportsCanonicalMonoPCMWithoutChangingOriginalAndFindsSidecar() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav"), original = try Data(contentsOf: url)
        try "Known lyrics\nSecond line".write(to: root.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let track = try XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let audio = try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(audio.count, 64044); XCTAssertEqual(String(decoding: audio.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(Array(audio[16..<36]), [16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0])
        XCTAssertTrue(audio[44...].contains { $0 != 0 })
        let text = try await LyricsAudioPreparation.existingText(track: track, folder: folder, embedded: "", expected: fingerprint)
        XCTAssertEqual(text, "Known lyrics\nSecond line")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["sample.txt", "sample.wav"])
    }
    func testChangedFileAndCancelledPreparationNeverReturnAudio() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav"), fingerprint = try FileFingerprint(url)
        let track = try XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder = try ScopedFolder(root)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)], ofItemAtPath: url.path)
        do { _ = try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: fingerprint); XCTFail("Changed audio must not be uploaded") }
        catch { XCTAssertEqual(error.localizedDescription, MetadataIOError.changed.localizedDescription) }
        let operation = Task { try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: FileFingerprint(url)) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Must cancel") } catch is CancellationError { }
    }
    func testFractionalDurationsKeepResampledAudioAndHeaderConsistent() async throws {
        for count: AVAudioFrameCount in [44101, 88202, 105841] {
            let root = try fixture(frames: count); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("sample.wav")
            let audio = try await LyricsAudioPreparation.prepare(track: XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder: ScopedFolder(root), expected: FileFingerprint(url))
            let frames = Double(audio.count - 44) / 2
            XCTAssertEqual(frames / 16000, Double(count) / 44100, accuracy: 1 / 16000)
            let length = Array(audio[40..<44]).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            XCTAssertEqual(length, audio.count - 44)
        }
    }

}
