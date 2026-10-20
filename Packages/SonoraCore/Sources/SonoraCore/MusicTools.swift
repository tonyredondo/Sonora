import Foundation

/// Rate and pitch are independent. Times elsewhere in the app remain source seconds.
public struct PlaybackAdjustment: Codable, Equatable, Sendable {
    public var rate: Float
    public var semitones: Float
    public init(rate: Float = 1, semitones: Float = 0) { self.rate = rate; self.semitones = semitones }
    public var validated: Self {
        Self(rate: rate.isFinite ? min(2, max(0.5, (rate * 20).rounded() / 20)) : 1,
             semitones: semitones.isFinite ? min(12, max(-12, semitones.rounded())) : 0)
    }
    public var isOriginal: Bool { rate == 1 && semitones == 0 }
}

public struct TempoEstimate: Codable, Equatable, Sendable {
    public let bpm: Double?
    public let confidence: Double
    public let variable: Bool

    /// Consensus across non-overlapping windows. Silence and rejected windows count
    /// against coverage; a confident short intro cannot label an entire song.
    public static func combine(_ windows: [BeatGrid?]) -> Self {
        let valid = windows.compactMap { $0 }.filter { $0.bpm.isFinite && $0.confidence >= 0.72 }
        guard let seed = valid.max(by: { a, b in
            valid.filter { abs($0.bpm / a.bpm - 1) < 0.05 }.count < valid.filter { abs($0.bpm / b.bpm - 1) < 0.05 }.count
        }) else { return Self(bpm: nil, confidence: 0, variable: false) }
        let matching = valid.filter { abs($0.bpm / seed.bpm - 1) < 0.05 }
        let coverage = Double(matching.count) / Double(max(1, windows.count))
        let varying = valid.count > matching.count && Double(matching.count) / Double(valid.count) < 0.8
        guard coverage >= 0.4 else { return Self(bpm: nil, confidence: coverage, variable: varying) }
        let weight = matching.reduce(0) { $0 + $1.confidence }
        let bpm = matching.reduce(0) { $0 + $1.bpm * $1.confidence } / weight
        return Self(bpm: bpm, confidence: min(1, weight / Double(matching.count) * coverage), variable: varying)
    }
}

public struct SongAnalysis: Codable, Equatable, Sendable {
    public static let version = "energy-v1"
    public let duration: Double
    public let waveform: [Float]
    public let tempo: TempoEstimate
    public init(duration: Double, waveform: [Float], tempo: TempoEstimate) {
        self.duration = duration; self.waveform = waveform; self.tempo = tempo
    }
    public var isValid: Bool {
        duration.isFinite && duration > 0 && duration <= 7200 && !waveform.isEmpty && waveform.count <= 1024
        && waveform.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        && tempo.confidence.isFinite && (0...1).contains(tempo.confidence)
        && (tempo.bpm.map { $0.isFinite && (40...300).contains($0) } ?? true)
    }
}

public struct SongMarker: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var time: Double
    public var title: String
    public init(id: UUID = UUID(), time: Double, title: String) { self.id = id; self.time = time; self.title = title }
}

public struct SongAnnotations: Codable, Equatable, Sendable {
    public var bpm: Double?
    public var markers: [SongMarker]
    public init(bpm: Double? = nil, markers: [SongMarker] = []) { self.bpm = bpm; self.markers = markers }
    public func validated(duration: Double) throws -> Self {
        guard duration.isFinite, duration > 0, markers.count <= 200,
              bpm.map({ $0.isFinite && (40...300).contains($0) }) ?? true,
              Set(markers.map(\.id)).count == markers.count,
              markers.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < duration && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 }) else {
            throw MusicTextError.invalid("Revisa el BPM y los marcadores: cada inicio debe estar dentro de la canción y tener un nombre.")
        }
        var result = self
        result.markers = markers.map { SongMarker(id: $0.id, time: $0.time, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time }
        return result
    }
}

public enum TapTempo {
    public static func bpm(taps: [Double]) -> Double? {
        guard taps.count >= 4, taps.allSatisfy(\.isFinite) else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map(-)
        guard intervals.allSatisfy({ (0.2...1.5).contains($0) }) else { return nil }
        let sorted = intervals.sorted(), median = sorted[sorted.count / 2]
        guard intervals.allSatisfy({ abs($0 / median - 1) < 0.3 }) else { return nil }
        return 60 / (intervals.reduce(0, +) / Double(intervals.count))
    }
}

/// Translation is attached by line identifier, never by response order or generated timing.
public struct LyricTranslation: Codable, Equatable, Sendable {
    public let lines: [Int: String]
    public init(lines: [Int: String], document: LyricsDocument) throws {
        let expected = Set(document.lines.filter { !$0.text.isEmpty }.map(\.id))
        guard Set(lines.keys) == expected, lines.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10000 }) else {
            throw MusicTextError.invalid("La traducción está incompleta. Reintenta para conservar todas las frases.")
        }
        self.lines = lines
    }
}
