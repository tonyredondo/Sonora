import AVFAudio
import SFBAudioEngine
import XCTest
@testable import Sonora

final class DecoderTests: XCTestCase {
    func testInitialFormatsAlsoProduceNormalizedCrossfadeAudio() throws {
        for ext in ["wav", "flac", "mp3", "m4a", "aiff", "alac.m4a"] {
            let name = ext == "alac.m4a" ? "fixture.alac" : "fixture"
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext == "alac.m4a" ? "m4a" : ext))
            let decoder = try NormalizedPCMDecoder(AudioDecoders.open(url))
            defer { try? decoder.close() }
            print("NORMALIZED CODEC: \(ext), expected \(decoder.length) frames")
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997))
            var frames = 0
            var peak: Float = 0
            repeat {
                try decoder.decode(into: buffer, length: buffer.frameCapacity)
                frames += Int(buffer.frameLength)
                peak = max(peak, UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)).map(abs).max() ?? 0)
                guard frames < 480000 else { XCTFail("Unexpectedly long fixture: \(ext)"); break }
            } while buffer.frameLength == buffer.frameCapacity
            XCTAssertEqual(Double(frames), Double(decoder.length), accuracy: 1, ext)
            print("NORMALIZED EOF: \(ext), rendered \(frames) frames")
            XCTAssertEqual(buffer.format.sampleRate, 48000, ext)
            XCTAssertGreaterThan(peak, 0.001, ext)
        }
    }
    func testInitialFormatsProduceAudioSamplesAndMetadata() throws {
        for ext in ["wav", "flac", "mp3", "m4a", "aiff", "alac.m4a"] {
            let name = ext == "alac.m4a" ? "fixture.alac" : "fixture"
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext == "alac.m4a" ? "m4a" : ext))
            let decoder = try AudioDecoders.open(url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 512))
            try decoder.decode(into: buffer, length: 512)
            XCTAssertGreaterThan(buffer.frameLength, 0, ext)
            XCTAssertEqual(decoder.processingFormat.channelCount, 2, ext)
            XCTAssertTrue(decoder.supportsSeeking, ext)
            let middle = decoder.length / 2
            try decoder.seek(to: middle)
            try decoder.decode(into: buffer, length: 64)
            XCTAssertGreaterThanOrEqual(decoder.position, middle, ext)
            XCTAssertGreaterThan(buffer.frameLength, 0, ext)
            try decoder.close()
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            XCTAssertGreaterThan(file.properties.duration ?? 0, 0, ext)
            if ["flac", "mp3", "m4a", "alac.m4a"].contains(ext) {
                XCTAssertEqual(file.metadata.title, "Señal de prueba", ext)
                XCTAssertEqual(file.metadata.artist, "Sonora Tests", ext)
            }
        }
    }
}
