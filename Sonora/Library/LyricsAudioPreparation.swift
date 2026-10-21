import AVFAudio
import Foundation
import SonoraCore

/// A bounded in-memory upload, decoded through the same format support as playback.
/// No temporary audio file or original-file mutation is needed.
enum LyricsAudioPreparation {
    /// Container metadata can estimate VBR duration. Use the playback decoder's
    /// frame count to preflight repair without decoding or uploading PCM yet.
    static func duration(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws -> Double {
        try await CoordinatedAudioRead.read(track:track,folder:folder,expected:expected) { url, _ in
            let source = try AudioDecoders.open(url,cue:track.cue)
            defer { try? source.close() }
            return Double(source.length) / source.processingFormat.sampleRate
        }
    }
    static func prepare(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws -> Data {
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
            let source = try AudioDecoders.open(url, cue: track.cue)
            defer { try? source.close() }
            let duration = Double(source.length) / source.processingFormat.sampleRate
            guard duration.isFinite, duration >= 1, duration <= 600,
                  let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw LyricsSynchronizationError.unsupportedDuration }
            let pcm = try NormalizedPCMDecoder(source, format: format)
            guard pcm.length >= 16000, pcm.length <= 9_600_000 else { throw LyricsSynchronizationError.unsupportedDuration }
            var data = PCM16WAV.header(bytes: UInt32(pcm.length * 2))
            data.reserveCapacity(44 + Int(pcm.length) * 2)
            var samples = [Int16](repeating: 0, count: 8192)
            while pcm.position < pcm.length {
                try Task.checkCancellation()
                try pcm.decode(into: buffer, length: buffer.frameCapacity)
                let count = Int(buffer.frameLength)
                guard count > 0, let input = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
                for frame in 0..<count {
                    let value = input[frame]
                    guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    samples[frame] = Int16(max(-32768, min(32767, Int((Double(max(-1, min(1, value))) * 32768).rounded())))).littleEndian
                }
                samples.withUnsafeBytes { data.append(contentsOf: $0.prefix(count * 2)) }
            }
            guard data.count == 44 + Int(pcm.length) * 2 else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }
    /// User edits must become effective without silently overriding or deleting an external lyric file.
    static func validateReplacement(_ text: String, track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws {
        let effective = try await existingText(track: track, folder: folder, embedded: text, expected: expected)
        guard effective.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MetadataIOError.externalLyrics
        }
    }
    static func existingText(track: AudioTrack, folder: ScopedFolder, embedded: String, expected: FileFingerprint) async throws -> String {
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, lyricsCoordinator in
            LyricsSource.read(for: url, embedded: embedded, coordinator: lyricsCoordinator).text
        }
    }
}

enum PCM16WAV {
    static func header(bytes: UInt32) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        append(bytes + 36); result.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16)); result.append(Data("data".utf8)); append(bytes)
        return result
    }
}
