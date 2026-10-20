import AVFAudio
import SonoraCore

/// Three 30-second regions at 15%, 50%, 85% of the available start range.
/// The same decoder and CUE boundaries as playback apply; uploads stay below 3 MB.
enum AudioCharacterPreparation {
    static func prepare(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws -> Data {
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
            let probe = try AudioDecoders.open(url, cue: track.cue)
            let duration = Double(probe.length) / probe.processingFormat.sampleRate
            let seeking = probe.supportsSeeking
            try probe.close()
            guard duration.isFinite, (1...86400).contains(duration), seeking || duration <= 30,
                  let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw MusicTextError.invalid("Este archivo no permite preparar las muestras para analizar su estilo.")
            }
            let offsets = duration <= 30 ? [0] : [0.15, 0.5, 0.85].map { ((duration - 30) * $0 * 1000).rounded() / 1000 }
            var audio = Data(); audio.reserveCapacity(2_880_000)
            var samples = [Int16](repeating: 0, count: 8192)
            for offset in offsets {
                try Task.checkCancellation()
                let source = try AudioDecoders.open(url, cue: track.cue)
                defer { try? source.close() }
                if offset > 0 { try source.seek(to: AVAudioFramePosition(offset * source.processingFormat.sampleRate)) }
                let decoder = try NormalizedPCMDecoder(source, format: format)
                var remaining = min(480_000, Int(decoder.length - decoder.position))
                guard remaining >= 16_000 else { throw CocoaError(.fileReadCorruptFile) }
                while remaining > 0 {
                    try Task.checkCancellation()
                    try decoder.decode(into: buffer, length: AVAudioFrameCount(min(8192, remaining)))
                    let count = Int(buffer.frameLength)
                    guard count > 0, let input = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
                    for frame in 0..<count {
                        guard input[frame].isFinite else { throw CocoaError(.fileReadCorruptFile) }
                        samples[frame] = Int16(max(-32768, min(32767, Int((Double(max(-1, min(1, input[frame]))) * 32768).rounded())))).littleEndian
                    }
                    samples.withUnsafeBytes { audio.append(contentsOf: $0.prefix(count * 2)) }
                    remaining -= count
                }
            }
            return PCM16WAV.header(bytes: UInt32(audio.count)) + audio
        }
    }
}
