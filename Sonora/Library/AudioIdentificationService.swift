import AVFAudio
import CChromaprint
import Foundation
import SonoraCore

struct AcousticFingerprint: Sendable {
    let fingerprint: String
    let duration: Int
}

enum AudioIdentificationService {
    static func fingerprint(track: AudioTrack, folder: ScopedFolder) async throws -> AcousticFingerprint {
        try Task.checkCancellation()
        let job = FingerprintRead()
        let worker = Task.detached(priority: .userInitiated) { try job.read(track: track, folder: folder) }
        return try await withTaskCancellationHandler {
            let value = try await worker.value; try Task.checkCancellation(); return value
        } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}

private final class FingerprintRead: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    func read(track: AudioTrack, folder: ScopedFolder) throws -> AcousticFingerprint {
        try Task.checkCancellation()
        let url = track.url(in: folder.url)
        let base = folder.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?, result: Result<AcousticFingerprint, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { local in
            result = Result {
                try Task.checkCancellation()
                let original = try FileFingerprint(local), source = try AudioDecoders.open(local, cue: track.cue)
                defer { try? source.close() }
                let duration = Double(source.length) / source.processingFormat.sampleRate
                guard duration.isFinite, duration > 0, duration <= 86400,
                      let context = chromaprint_new(1) else { throw FingerprintError.failed }
                defer { chromaprint_free(context) }
                // This package omits FFmpeg's resampler. Convert explicitly to the
                // algorithm's rate using the same decoder path as local playback.
                let rate = chromaprint_get_sample_rate(context)
                guard rate > 1000, let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
                      chromaprint_start(context, rate, 1) == 1 else { throw FingerprintError.failed }
                let pcm = try NormalizedPCMDecoder(source, format: format)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw FingerprintError.failed }
                var samples = [Int16](repeating: 0, count: 8192), read = 0
                let limit = Int(min(120 * Double(rate), Double(pcm.length)))
                while read < limit {
                    try Task.checkCancellation()
                    try pcm.decode(into: buffer, length: AVAudioFrameCount(min(samples.count, limit - read)))
                    let count = Int(buffer.frameLength)
                    if count == 0 { break }
                    guard let input = buffer.floatChannelData?[0] else { throw FingerprintError.failed }
                    for frame in 0..<count {
                        let value = input[frame]
                        guard value.isFinite else { throw FingerprintError.failed }
                        samples[frame] = Int16(max(-32768, min(32767, Int((Double(max(-1, min(1, value))) * 32768).rounded()))))
                    }
                    let accepted = samples.withUnsafeBufferPointer { chromaprint_feed(context, $0.baseAddress, Int32(count)) }
                    guard accepted == 1 else { throw FingerprintError.failed }
                    read += count
                }
                try Task.checkCancellation()
                guard chromaprint_finish(context) == 1 else { throw FingerprintError.failed }
                var size: Int32 = 0
                guard chromaprint_get_raw_fingerprint_size(context, &size) == 1, size > 0 else { throw FingerprintError.tooShort }
                var encoded: UnsafeMutablePointer<CChar>?
                guard chromaprint_get_fingerprint(context, &encoded) == 1, let encoded else { throw FingerprintError.failed }
                defer { chromaprint_dealloc(encoded) }
                guard try FileFingerprint(local) == original else { throw MetadataIOError.changed }
                try Task.checkCancellation()
                return AcousticFingerprint(fingerprint: String(cString: encoded), duration: max(1, Int(duration.rounded())))
            }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}

private enum FingerprintError: LocalizedError {
    case tooShort, failed
    var errorDescription: String? {
        switch self {
        case .tooShort: "El audio es demasiado corto para generar una huella reconocible. Puedes buscar por título y artista."
        case .failed: "No se pudo calcular la huella de este audio. Puedes buscar por título y artista."
        }
    }
}
