import AVFAudio
import ChromaSwift
import CryptoKit
import SonoraCore
import XCTest
@testable import Sonora

final class AudioIdentificationTests: XCTestCase {
    private func sample(_ url: URL, seconds: Int = 16) throws {
        let rate = 11025.0, format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11025)!
        for second in 0..<seconds {
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<11025 {
                let time = Double(second) + Double(frame) / rate, frequency = [220.0, 330, 440, 277][(second / 2) % 4]
                buffer.floatChannelData![0][frame] = Float(0.2 * sin(2 * .pi * frequency * time) + 0.1 * sin(2 * .pi * frequency * 1.5 * time))
            }
            try output.write(from: buffer)
        }
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testFingerprintMatchesIndependentAVFoundationDecodeAndDoesNotWriteAudio() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav"); try sample(url)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let reference = try AudioFingerprint(from: url).base64
        let value = try await AudioIdentificationService.fingerprint(track: XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder: ScopedFolder(root))
        XCTAssertEqual(value.duration, 16); XCTAssertEqual(value.fingerprint, reference)
        XCTAssertGreaterThan(value.fingerprint.count, 20)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
    }

    func testShortAudioEscapingSymlinksAndCancellationCannotProduceFingerprint() async throws {
        let root = try root(), outside = try self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try sample(root.appendingPathComponent("short.wav"), seconds: 1)
        try sample(outside.appendingPathComponent("outside.wav"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.wav"), withDestinationURL: outside.appendingPathComponent("outside.wav"))
        let folder = try ScopedFolder(root)
        for name in ["short.wav", "escape.wav"] {
            do { _ = try await AudioIdentificationService.fingerprint(track: XCTUnwrap(AudioTrack(relativePath: name)), folder: folder); XCTFail("Must reject \(name)") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        let worker = Task { try await AudioIdentificationService.fingerprint(track: XCTUnwrap(AudioTrack(relativePath: "escape.wav")), folder: folder) }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled analysis cannot be used") }
        catch is CancellationError { }
    }

    func testAnalysisStopsAtTwoMinutesButSendsFullFileDuration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("long.wav"); try sample(url, seconds: 125)
        let reference = try AudioFingerprint(from: url, maxSampleDuration: 120).base64
        let value = try await AudioIdentificationService.fingerprint(track: XCTUnwrap(AudioTrack(relativePath: "long.wav")), folder: ScopedFolder(root))
        XCTAssertEqual(value.duration, 125)
        XCTAssertEqual(value.fingerprint, reference)
    }
}
