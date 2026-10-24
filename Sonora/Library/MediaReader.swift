import AVFAudio
import ImageIO
import SFBAudioEngine
import SonoraCore
import UIKit

struct TrackDetails {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let format: String
    let sampleRate: Double
    var artwork: UIImage?
    var tags: [MetadataField: String] = [:]
    var lyrics = LyricsDocument(text: "")
    var lyricsSource: String? = nil
    var replayGain = ReplayGain()
    var normalizationGain: Double = 1
    var rhythm: AudioRhythmAnalysis? = nil
    var fingerprint: FileFingerprint? = nil
}

/// Immutable result transferred once from the I/O worker to the player owner.
struct PreparedTrack: @unchecked Sendable {
    let decoder: any PCMDecoding
    let details: TrackDetails
}

private final class CoordinatedRead: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    func prepare(_ track: AudioTrack, folder: ScopedFolder, position: Double, normalization: NormalizationMode, balance: Float, analyzeRhythm: Bool, volume: VolumeAnalysisCandidate?) throws -> PreparedTrack {
        let url = track.url(in: folder.url)
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?
        var result: Result<PreparedTrack, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { localURL in
            result = Result {
                let decoder = try AudioDecoders.open(localURL, cue: track.cue)
                if position.isFinite, position > 0, decoder.supportsSeeking {
                    let target = min(Double(max(0, decoder.length - 1)), position * decoder.processingFormat.sampleRate)
                    try decoder.seek(to: AVAudioFramePosition(target))
                }
                let file = ["caf", "aac"].contains(localURL.pathExtension.lowercased()) ? nil : try? AudioFile(readingPropertiesAndMetadataFrom: localURL)
                let metadata = file?.metadata
                let rhythm = analyzeRhythm ? try AudioRhythmAnalyzer.analyze(localURL, cue: track.cue) : nil
                var replayGain = MetadataService.replayGain(metadata)
                if let cue = track.cue, cue.startCDFrame > 0 || cue.endCDFrame != nil { replayGain.trackGain = nil; replayGain.trackPeak = nil }
                if normalization != .off, let volume, let measured = volume.validated(fingerprint: try FileFingerprint(localURL)) {
                    replayGain.trackGain = measured.trackGain; replayGain.trackPeak = measured.trackPeak
                    if let gain = measured.albumGain, let peak = measured.albumPeak { replayGain.albumGain = gain; replayGain.albumPeak = peak }
                }
                let gain = replayGain.multiplier(for: normalization)
                var output: any PCMDecoding = ScopedPCMDecoder(decoder, folder: folder)
                if gain != 1 || balance != 0 {
                    let format = AVAudioFormat(standardFormatWithSampleRate: decoder.processingFormat.sampleRate, channels: balance == 0 ? decoder.processingFormat.channelCount : 2)!
                    output = try NormalizedPCMDecoder(output, format: format, gain: gain, balance: balance)
                }
                let bits = file?.properties.bitDepth.map { " · \($0) bit" } ?? ""
                let data = metadata?.attachedPictures.first?.imageData
                let tags = track.tags(overriding: metadata.map(MetadataService.values) ?? [:])
                return PreparedTrack(decoder: output, details: TrackDetails(
                    title: tags[.title]?.nonempty ?? track.displayName,
                    artist: tags[.artist]?.nonempty ?? "Artista desconocido",
                    album: tags[.album]?.nonempty ?? (track.folder.isEmpty ? folder.url.lastPathComponent : track.folder),
                    // VBR metadata can be an estimate; seeking and fragment
                    // playback must use the decoder's known sample interval.
                    duration: decoder.length > 0 ? Double(decoder.length) / decoder.processingFormat.sampleRate : file?.properties.duration ?? 0,
                    format: localURL.pathExtension.uppercased() + bits + String(format: " / %.1f kHz", decoder.processingFormat.sampleRate / 1000),
                    sampleRate: decoder.processingFormat.sampleRate,
                    artwork: (metadata?.attachedPictures(ofType: .frontCover).first?.imageData ?? data).flatMap(Self.thumbnail) ?? Self.sidecarArtwork(for: localURL),
                    tags: tags, replayGain: replayGain, normalizationGain: gain, rhythm: rhythm, fingerprint: try FileFingerprint(localURL)
                ))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CancellationError() }
        let prepared = try result.get()
        var details = prepared.details
        let lyrics = LyricsSource.read(for: url, embedded: details.tags[.lyrics] ?? "", coordinator: coordinator)
        details.lyrics = LyricsDocument(text: lyrics.text)
        if let cue = track.cue { details.lyrics = details.lyrics.sliced(from: cue.startSeconds, duration: details.duration) }
        details.lyricsSource = details.lyrics.attribution ?? lyrics.source
        return PreparedTrack(decoder: prepared.decoder, details: details)
    }
    private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private static func sidecarArtwork(for audio: URL) -> UIImage? {
        LocalArtwork.data(for: audio).flatMap(thumbnail)
    }
}

enum MediaReader {
    static func prepare(_ track: AudioTrack, folder: ScopedFolder, position: Double = 0, normalization: NormalizationMode = .off, balance: Float = 0, analyzeRhythm: Bool = false, volume: VolumeAnalysisCandidate? = nil) async throws -> PreparedTrack {
        let job = CoordinatedRead()
        let worker = Task.detached(priority: .userInitiated) { try job.prepare(track, folder: folder, position: position, normalization: normalization, balance: balance, analyzeRhythm: analyzeRhythm, volume: volume) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}

private extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
