import AVFAudio
import CryptoKit
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

final class AdditionalCodecTests: XCTestCase {
    private func source(_ ext: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "extra", withExtension: ext)) }
    private func audioHash(_ url: URL) throws -> (String, Int) {
        let decoder = try NormalizedPCMDecoder(AudioDecoders.open(url)); defer { try? decoder.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
        var hash = SHA256(), frames = 0
        repeat {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            frames += Int(buffer.frameLength)
            for channel in 0..<2 { hash.update(data: Data(bytes: buffer.floatChannelData![channel], count: Int(buffer.frameLength) * 4)) }
            guard frames < 240000 else { throw CocoaError(.fileReadCorruptFile) }
        } while buffer.frameLength == buffer.frameCapacity
        XCTAssertEqual(Double(frames), Double(decoder.length), accuracy: 1)
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), frames)
    }
    func testAdditionalCodecsDecodeToEndSeekAndExposeDuration() async throws {
        for ext in ["ogg", "opus", "wv", "tta", "caf", "aac"] {
            print("CODEC START: \(ext)")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("extra." + ext); try FileManager.default.copyItem(at: source(ext), to: url)
            let decoder = try AudioDecoders.open(url)
            XCTAssertTrue(decoder.supportsSeeking, ext)
            try decoder.seek(to: decoder.length / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 512)!
            try decoder.decode(into: buffer, length: 512); XCTAssertGreaterThan(buffer.frameLength, 0, ext)
            try decoder.close()
            let decoded = try audioHash(url); XCTAssertGreaterThan(decoded.1, 80000, ext)
            print("CODEC decoded: \(ext)")
            let folder = try ScopedFolder(root)
            let track = try await MediaReader.prepare(AudioTrack(relativePath: "extra." + ext)!, folder: folder)
            XCTAssertGreaterThan(track.details.duration, 1.9, ext); try track.decoder.close()
            print("CODEC details: \(ext)")
            let metadata = try await MetadataService.read(url: url, folder: folder)
            XCTAssertGreaterThan(metadata.duration, 1.9, ext)
            if ["caf", "aac", "tta"].contains(ext) { XCTAssertFalse(metadata.canWrite, ext) }
            print("ADDITIONAL CODEC: \(ext), \(decoded.1) normalizedframes,seek+EOF+duration")
        }
    }
    func testAdditionalWritableFormatsPreserveAudioAndEmbeddedLyrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!.imageData
        for ext in ["ogg", "opus", "wv"] {
            let url = root.appendingPathComponent("extra." + ext); try FileManager.default.copyItem(at: source(ext), to: url)
            let original = try audioHash(url).0, metadata = try await MetadataService.read(url: url, folder: folder)
            let patch = MetadataPatch(values: [.title: "Título editado", .artist: "Artista", .album: "Álbum", .albumArtist: "Artista del álbum", .composer: "Compositor", .genre: "Jazz", .date: "2026", .trackNumber: "3", .trackTotal: "10", .discNumber: "1", .discTotal: "2", .comment: "Comentario", .lyrics: "[00:00]Una letra\n[00:01]Dos"], artwork: .replace(cover))
            let saved = try await MetadataService.save(url: url, folder: folder, expected: metadata.fingerprint, patch: patch)
            for (field, text) in patch.values { XCTAssertEqual(saved.values[field], text, "\(ext):\(field)") }
            XCTAssertEqual(saved.artwork, cover, ext); XCTAssertEqual(try audioHash(url).0, original, ext)
        }
    }
}
