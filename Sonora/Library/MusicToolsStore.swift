import Accelerate
import AVFAudio
import CryptoKit
import Observation
import SonoraCore

/// Derived results are disposable. User BPM corrections and markers live separately
/// and are never evicted with the analysis cache.
actor MusicToolsCache {
    static let shared = MusicToolsCache()
    private let root: URL
    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("MusicTools", isDirectory: true)) { self.root = root }
    nonisolated static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func file(_ key: String, personal: Bool) -> URL {
        root.appendingPathComponent(personal ? "annotations" : "cache", isDirectory: true).appendingPathComponent(Self.digest(key) + ".json")
    }
    func read<T: Decodable & Sendable>(_ type: T.Type, key: String, personal: Bool = false) throws -> T? {
        let url = file(key, personal: personal)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            if personal { throw error }
            return nil // Only generated results may be recomputed after corruption.
        }
    }
    func write<T: Encodable & Sendable>(_ value: T, key: String, personal: Bool = false) throws {
        let url = file(key, personal: personal), data = try JSONEncoder().encode(value)
        guard data.count <= 2_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if !personal { try prune() }
    }
    private func prune() throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" }.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1.fileSize ?? 0
            if index >= 512 || bytes > 32_000_000 { try FileManager.default.removeItem(at: entry.0) }
        }
    }
}

struct SongToolsResult: Sendable {
    let contentID: String
    let fingerprint: FileFingerprint
    let analysis: SongAnalysis
    var annotations: SongAnnotations
    var bpm: Double? { annotations.bpm ?? analysis.tempo.bpm }
}

@MainActor @Observable
final class MusicToolsStore {
    private var summaries: [String: SongToolsResult] = [:]
    @ObservationIgnored private let cache: MusicToolsCache
    private struct Identity: Codable, Sendable { let fingerprint: FileFingerprint; let contentID: String }
    init(cache: MusicToolsCache = .shared) { self.cache = cache }

    private func identityKey(track: AudioTrack, folder: ScopedFolder) -> String {
        // Queue and library entries may have different source-qualified IDs.
        // The file URL plus local ID also keeps separate CUE segments distinct.
        "identity-v1:\(track.localID):\(track.url(in: folder.url).standardizedFileURL.absoluteString)"
    }
    func summary(for track: AudioTrack, folder: ScopedFolder) -> SongToolsResult? {
        summaries[identityKey(track: track, folder: folder)]
    }

    /// Restore only an already measured, unchanged file; never start analysis on playback.
    func restore(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws {
        let key = identityKey(track: track, folder: folder)
        if summaries[key]?.fingerprint == expected { return }
        summaries[key] = nil
        guard let binding = try await cache.read(Identity.self, key: key), binding.fingerprint == expected,
              let analysis = try await cache.read(SongAnalysis.self, key: "analysis:\(SongAnalysis.version):\(binding.contentID)"), analysis.isValid else { return }
        let annotations = try await cache.read(SongAnnotations.self, key: binding.contentID, personal: true) ?? SongAnnotations()
        try Task.checkCancellation()
        summaries[key] = SongToolsResult(contentID: binding.contentID, fingerprint: expected, analysis: analysis, annotations: try annotations.validated(duration: analysis.duration))
    }

    func load(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint,
              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SongToolsResult {
        let identityKey = identityKey(track: track, folder: folder)
        // Bound work before hashing a potentially very long source.
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
            let decoder = try AudioDecoders.open(url, cue: track.cue)
            defer { try? decoder.close() }
            let duration = Double(decoder.length) / decoder.processingFormat.sampleRate
            guard duration.isFinite, duration > 0, duration <= 7200 else {
                throw MusicTextError.invalid("El análisis admite canciones de hasta dos horas.")
            }
        }
        let previous = try await cache.read(Identity.self, key: identityKey)
        let contentID: String
        if let previous, previous.fingerprint == expected {
            contentID = try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { _, _ in previous.contentID }
        } else {
            contentID = try await AudioContentIdentity.read(track: track, folder: folder, expected: expected)
            try await cache.write(Identity(fingerprint: expected, contentID: contentID), key: identityKey)
        }
        let key = "analysis:\(SongAnalysis.version):\(contentID)"
        let analysis: SongAnalysis
        if let cached = try await cache.read(SongAnalysis.self, key: key), cached.isValid { analysis = cached }
        else {
            analysis = try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
                try SongAudioAnalyzer.analyze(url: url, track: track, progress: progress)
            }
            try Task.checkCancellation()
            try await cache.write(analysis, key: key)
        }
        let annotations = try await cache.read(SongAnnotations.self, key: contentID, personal: true) ?? SongAnnotations()
        let result = SongToolsResult(contentID: contentID, fingerprint: expected, analysis: analysis, annotations: try annotations.validated(duration: analysis.duration))
        try Task.checkCancellation()
        summaries[identityKey] = result
        return result
    }
    func save(_ annotations: SongAnnotations, for track: AudioTrack, folder: ScopedFolder, result: SongToolsResult) async throws -> SongToolsResult {
        let value = try annotations.validated(duration: result.analysis.duration)
        try await cache.write(value, key: result.contentID, personal: true)
        var updated = result; updated.annotations = value
        // All loaded copies with the same audio hash share personal annotations.
        for key in summaries.keys where summaries[key]?.contentID == result.contentID {
            summaries[key]?.annotations = value
        }
        summaries[identityKey(track: track, folder: folder)] = updated
        return updated
    }
}

enum SongAudioAnalyzer {
    /// Full-track energy and waveform in fixed PCM buffers. At most 20 seconds of
    /// envelope is retained; the final waveform has 1024 bins regardless of length.
    static func analyze(url: URL, track: AudioTrack, progress: @Sendable (Double) -> Void) throws -> SongAnalysis {
        let source = try AudioDecoders.open(url, cue: track.cue)
        let decoder: NormalizedPCMDecoder
        do { decoder = try NormalizedPCMDecoder(source) } catch { try? source.close(); throw error }
        defer { try? decoder.close() }
        let duration = Double(decoder.length) / decoder.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 7200,
              let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192) else {
            throw MusicTextError.invalid("El análisis admite canciones de hasta dos horas.")
        }
        let total = Int(decoder.length), bucketSize = max(1, Int(ceil(Double(total) / 1024)))
        var waveform = [Float](repeating: 0, count: min(1024, total))
        var energy: [Double] = [], windows: [BeatGrid?] = []
        var frame = 0, count = 0, sum = 0.0
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(180))
        var nextProgress = clock.now
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw MusicTextError.invalid("El análisis ha tardado demasiado. Puedes volver a intentarlo.") }
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard frame + frames <= total, let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            var offset = 0
            while offset < frames {
                let bucket = min(waveform.count - 1, frame / bucketSize)
                let size = min(frames - offset, 480 - count, bucketSize - frame % bucketSize)
                var left: Float = 0, right: Float = 0, peakL: Float = 0, peakR: Float = 0
                vDSP_svesq(channels[0] + offset, 1, &left, vDSP_Length(size))
                vDSP_svesq(channels[1] + offset, 1, &right, vDSP_Length(size))
                vDSP_maxmgv(channels[0] + offset, 1, &peakL, vDSP_Length(size))
                vDSP_maxmgv(channels[1] + offset, 1, &peakR, vDSP_Length(size))
                guard left.isFinite, right.isFinite, peakL.isFinite, peakR.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                waveform[bucket] = max(waveform[bucket], min(1, max(peakL, peakR)))
                sum += Double(left + right) / 2; count += size; offset += size; frame += size
                if count == 480 {
                    energy.append(sqrt(sum / 480)); sum = 0; count = 0
                    if energy.count == 2000 { windows.append(RhythmAnalyzer.estimate(energy: energy)); energy.removeAll(keepingCapacity: true) }
                }
            }
            if clock.now >= nextProgress { progress(Double(frame) / Double(total)); nextProgress = clock.now.advanced(by: .milliseconds(250)) }
        }
        // The resampler can round the advertised length up by one frame. Its
        // decoder already rejects a genuinely truncated tail.
        guard frame > 0, total - frame <= 1 else { throw CocoaError(.fileReadCorruptFile) }
        if energy.count >= 600 { windows.append(RhythmAnalyzer.estimate(energy: energy)) }
        progress(1)
        return SongAnalysis(duration: duration, waveform: waveform, tempo: .combine(windows))
    }
}
