import AVFAudio
import Foundation

struct VolumeAnalysisProgress: Sendable {
    let completed: Int
    let total: Int
    let fraction: Double
    let filename: String
}

enum VolumeAnalysisService {
    /// An unreadable file is a cache miss here. The explicit analysis reports its
    /// I/O error and, for cloud files, requests the audio download.
    static func availableFingerprints(_ targets: [VolumeAnalysisTarget]) async throws -> [String: FileFingerprint] {
        let worker = Task.detached(priority: .utility) {
            var values: [String: FileFingerprint] = [:]
            for target in targets {
                try Task.checkCancellation()
                if let value = try? FileFingerprint(target.url) { values[target.id] = value }
            }
            return values
        }
        return try await withTaskCancellationHandler {
            let values = try await worker.value; try Task.checkCancellation(); return values
        } onCancel: { worker.cancel() }
    }
    static func cachedGain(_ candidate: VolumeAnalysisCandidate, url: URL) async throws -> ReplayGain? {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return candidate.validated(fingerprint: try FileFingerprint(url))
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value; try Task.checkCancellation(); return value
        } onCancel: { worker.cancel() }
    }
    static func analyze(_ targets: [VolumeAnalysisTarget], album: Bool,
                        progress: @escaping @Sendable (VolumeAnalysisProgress) -> Void = { _ in }) async throws -> VolumeAnalysisBatch {
        let job = VolumeAnalysisJob(targets: targets)
        let worker = Task.detached(priority: .utility) { try job.analyze(album: album, progress: progress) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}

private final class VolumeAnalysisJob: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    private let targets: [VolumeAnalysisTarget]
    init(targets: [VolumeAnalysisTarget]) { self.targets = targets }

    func analyze(album: Bool, progress: @escaping @Sendable (VolumeAnalysisProgress) -> Void) throws -> VolumeAnalysisBatch {
        guard !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else { throw CocoaError(.fileReadInvalidFileName) }
        var records: [String: VolumeTrackMeasurement] = [:], meters: [VolumeLoudnessMeter] = []
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let base = target.folder.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard target.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
                  try target.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
            if (try? target.url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                try FileManager.default.startDownloadingUbiquitousItem(at: target.url)
            }
            var coordinationError: NSError?, outcome: Result<(VolumeTrackMeasurement, VolumeLoudnessMeter), Error>?
            progress(.init(completed: index, total: targets.count, fraction: 0, filename: target.url.lastPathComponent))
            coordinator.coordinate(readingItemAt: target.url, options: .withoutChanges, error: &coordinationError) { local in
                outcome = Result {
                    try Task.checkCancellation()
                    let fingerprint = try FileFingerprint(local), decoder = try AudioDecoders.open(local, cue: target.cue)
                    defer { try? decoder.close() }
                    let input = decoder.processingFormat
                    let format: AVAudioFormat?
                    if let layout = input.channelLayout {
                        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, interleaved: false, channelLayout: layout)
                    } else { format = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: input.channelCount) }
                    guard let format else { throw CocoaError(.fileReadCorruptFile) }
                    let pcm = try NormalizedPCMDecoder(decoder, format: format)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw CocoaError(.fileReadTooLarge) }
                    let meter = try VolumeLoudnessMeter(format: format)
                    var lastUpdate = Date.timeIntervalSinceReferenceDate, lastFraction = 0.0
                    repeat {
                        try Task.checkCancellation()
                        try pcm.decode(into: buffer, length: buffer.frameCapacity)
                        if buffer.frameLength > 0 { try meter.append(buffer) }
                        let now = Date.timeIntervalSinceReferenceDate
                        let fraction = min(0.999, Double(pcm.position) / Double(max(1, pcm.length)))
                        if now - lastUpdate >= 0.1 || fraction - lastFraction >= 0.05 {
                            progress(.init(completed: index, total: targets.count, fraction: fraction, filename: target.url.lastPathComponent))
                            lastUpdate = now; lastFraction = fraction
                        }
                    } while buffer.frameLength > 0
                    try Task.checkCancellation()
                    guard try FileFingerprint(local) == fingerprint else { throw MetadataIOError.changed }
                    let value = VolumeTrackMeasurement(fingerprint: fingerprint, gain: try meter.gain().doubleValue, peak: meter.peak, measuredAt: Date())
                    guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
                    return (value, meter)
                }
            }
            try Task.checkCancellation()
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CancellationError() }
            let measured = try outcome.get()
            records[target.id] = measured.0
            if album { meters.append(measured.1) }
            progress(.init(completed: index + 1, total: targets.count, fraction: 0, filename: target.url.lastPathComponent))
        }
        try Task.checkCancellation()
        // Recheck the whole album after reading its final file, so an earlier
        // member changed during analysis cannot leave a seemingly valid result.
        for target in targets where (try? FileFingerprint(target.url)) != records[target.id]?.fingerprint { throw MetadataIOError.changed }
        let combined: VolumeAlbumMeasurement?
        if album {
            combined = VolumeAlbumMeasurement(id: UUID().uuidString, members: records.mapValues(\.fingerprint),
                                               gain: try VolumeLoudnessMeter.albumGain(for: meters).doubleValue,
                                               peak: records.values.map(\.peak).max() ?? 0)
        } else { combined = nil }
        return VolumeAnalysisBatch(records: records, album: combined)
    }
}
