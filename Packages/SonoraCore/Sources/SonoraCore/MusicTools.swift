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
    // Keep the measured value in the existing cache format. Applying the
    // metrical preference on read also updates previously cached analyses.
    let detectedBPM: Double?
    public var bpm: Double? { detectedBPM.map(Self.preferredBPM) }
    public let confidence: Double
    public let variable: Bool

    private enum CodingKeys: String, CodingKey { case detectedBPM = "bpm", confidence, variable }
    public init(bpm: Double?, confidence: Double, variable: Bool) {
        detectedBPM = bpm; self.confidence = confidence; self.variable = variable
    }
    static func preferredBPM(_ bpm: Double) -> Double {
        bpm > 170 && bpm <= 300 ? bpm / 2 : bpm
    }

    /// Display estimates need a representative tempo; alignment also needs beat
    /// phase. Weak agreement lowers confidence, not visibility.
    public static func combine(_ windows: [BeatGrid?]) -> Self {
        combine(estimates: windows.map { Self(bpm: $0?.bpm, confidence: $0?.confidence ?? 0, variable: false) })
    }

    public static func combine(estimates windows: [Self]) -> Self {
        let valid = windows.filter { $0.bpm.map { $0.isFinite && (40...300).contains($0) } == true && $0.confidence.isFinite && $0.confidence > 0 && $0.confidence <= 1 }
        // A short rhythmic intro cannot stand in for an otherwise silent track.
        guard Double(valid.count) / Double(max(1, windows.count)) >= 0.4,
              !valid.isEmpty else { return Self(bpm: nil, confidence: 0, variable: false) }
        guard let seed = valid.max(by: { a, b in
            valid.filter { abs($0.bpm! / a.bpm! - 1) < 0.05 }.reduce(0) { $0 + $1.confidence }
                < valid.filter { abs($0.bpm! / b.bpm! - 1) < 0.05 }.reduce(0) { $0 + $1.confidence }
        }) else { return Self(bpm: nil, confidence: 0, variable: false) }
        let matching = valid.filter { abs($0.bpm! / seed.bpm! - 1) < 0.05 }
        let coverage = Double(matching.count) / Double(max(1, windows.count))
        let varying = valid.contains(where: \.variable) || Double(matching.count) / Double(valid.count) < 0.8
        let weight = matching.reduce(0) { $0 + $1.confidence }
        let representative = coverage >= 0.4 ? matching : valid
        let totalWeight = representative.reduce(0) { $0 + $1.confidence }
        let bpm = representative.reduce(0) { $0 + $1.bpm! * $1.confidence } / totalWeight
        return Self(bpm: bpm, confidence: min(1, weight / Double(matching.count) * coverage), variable: varying)
    }

    /// Estimate tempo from onset periodicity without demanding a fixed beat phase.
    /// Small timing variations and quieter offbeats are normal in recorded music.
    public static func estimate(energy: [Double], hop: Double = 0.01) -> Self {
        let unavailable = Self(bpm: nil, confidence: 0, variable: false)
        guard hop.isFinite, (0.005...0.02).contains(hop),
              energy.count >= Int(6 / hop), energy.count <= 4000,
              energy.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return unavailable }
        // Preserve the well-tested exact estimate when the pulse is unambiguous.
        if let grid = RhythmAnalyzer.estimate(energy: energy, hop: hop) {
            return Self(bpm: grid.bpm, confidence: grid.confidence, variable: false)
        }
        let changes = energy.indices.map { max(0, energy[$0] - ($0 == 0 ? 0 : energy[$0 - 1])) }
        guard let peak = changes.max(), peak > 0.00001,
              changes.filter({ $0 > peak * 0.1 }).count >= 6 else { return unavailable }
        // A 30 ms triangular window tolerates human timing and envelope jitter.
        let radius = max(1, Int((0.03 / hop).rounded()))
        var onsets = [Double](repeating: 0, count: changes.count)
        for i in changes.indices {
            for j in max(0, i - radius)...min(changes.count - 1, i + radius) {
                onsets[i] += changes[j] / peak * Double(radius + 1 - abs(j - i))
            }
        }
        let strong = (onsets.max() ?? 0) * 0.55
        let peaks = (1..<(onsets.count - 1)).filter {
            onsets[$0] >= strong && onsets[$0] > onsets[$0 - 1] && onsets[$0] >= onsets[$0 + 1]
        }
        let intervals = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) * hop }
            .filter { (0.2...1.5).contains($0) }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        onsets = onsets.map { $0 - mean }
        let lower = max(1, Int((60 / 300.0 / hop).rounded(.down)))
        let upper = Int((60 / 40.0 / hop).rounded(.up))
        func correlation(_ lag: Int) -> Double {
            var cross = 0.0, a = 0.0, b = 0.0
            for i in lag..<onsets.count {
                let x = onsets[i], y = onsets[i - lag]
                cross += x * y; a += x * x; b += y * y
            }
            return a * b > 0 ? cross / sqrt(a * b) : 0
        }
        let first = max(1, lower - 1)
        let scores = (first...(upper + 1)).map(correlation)
        var best: (bpm: Double, strength: Double, rank: Double)?
        for lag in lower...upper {
            let index = lag - first, strength = scores[index]
            let before = scores[max(0, index - 1)], after = scores[min(scores.count - 1, index + 1)]
            guard strength >= 0.12, strength >= before, strength >= after else { continue }
            let denominator = before - 2 * strength + after
            let correction = abs(denominator) > 0.00001 ? min(0.5, max(-0.5, 0.5 * (before - after) / denominator)) : 0
            let period = (Double(lag) + correction) * hop
            let matching = intervals.filter { abs($0 / period - 1) < 0.2 }
            let support = Double(matching.count) / Double(max(1, intervals.count))
            // Accents repeating every three or four beats can dominate correlation.
            // Intervals between strong attacks distinguish those from the beat.
            let rank = intervals.count >= 6 ? 0.5 * strength + 0.5 * support : strength
            let ranked = rank - 0.03 * abs(log2((60 / period) / 120))
            let refined = matching.count >= 6 ? matching.reduce(0, +) / Double(matching.count) : period
            let bpm = min(300, max(40, 60 / refined))
            if best == nil || ranked > best!.rank { best = (bpm, rank, ranked) }
        }
        guard let best else { return unavailable }
        return Self(bpm: best.bpm, confidence: min(0.7, max(0.05, best.strength)), variable: false)
    }
}

public struct SongAnalysis: Codable, Equatable, Sendable {
    public static let version = "rms-v3"
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

    /// Reduce RMS energy to the visible bars, using one linear scale for the
    /// whole song. A peak in a quiet passage must not fill that passage's bar.
    public func waveformLevels(count: Int) -> [Float] {
        guard count > 0, !waveform.isEmpty else { return [] }
        let count = min(count, 1024)
        let span = Double(waveform.count) / Double(count)
        // Do not magnify near-silence into a full-height waveform.
        let reference = max(0.05, Double(waveform.max() ?? 0))
        return (0..<count).map { column in
            let start = Double(column) * span
            let end = min(Double(waveform.count), Double(column + 1) * span)
            var energy = 0.0
            for index in Int(start)..<Int(ceil(end)) {
                let overlap = min(end, Double(index + 1)) - max(start, Double(index))
                let level = Double(waveform[index])
                energy += level * level * overlap
            }
            return Float(min(1, sqrt(energy / span) / reference))
        }
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

/// Translation is attached to original lines. A contextual phrase can cover
/// several consecutive lines and appears at the first line's existing time.
public struct LyricTranslation: Codable, Equatable, Sendable {
    public struct Phrase: Codable, Equatable, Sendable {
        public let lineIDs: [Int]
        public let text: String
        public init(lineIDs: [Int], text: String) { self.lineIDs = lineIDs; self.text = text }
    }
    public let lines: [Int: String]
    public let phrases: [Phrase]?
    public init(lines: [Int: String], document: LyricsDocument) throws {
        let expected = Set(document.lines.filter { !$0.text.isEmpty }.map(\.id))
        guard Set(lines.keys) == expected, lines.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10000 }) else {
            throw MusicTextError.invalid("La traducción está incompleta. Reintenta para conservar todas las frases.")
        }
        self.lines = lines
        self.phrases = nil
    }
    public init(phrases: [Phrase], document: LyricsDocument) throws {
        let expected = document.lines.filter { !$0.text.isEmpty }.map(\.id)
        guard !expected.isEmpty, phrases.flatMap(\.lineIDs) == expected,
              phrases.allSatisfy({ !$0.lineIDs.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 100000 }) else {
            throw MusicTextError.invalid("La traducción está incompleta. Reintenta para conservar todas las frases.")
        }
        self.phrases = phrases
        self.lines = Dictionary(uniqueKeysWithValues: phrases.map { ($0.lineIDs[0], $0.text) })
    }
    public func validated(for document: LyricsDocument) throws -> Self {
        if let phrases {
            let valid = try Self(phrases: phrases, document: document)
            guard valid.lines == lines else { throw MusicTextError.invalid("La traducción guardada no coincide con sus frases.") }
            return valid
        }
        return try Self(lines: lines, document: document)
    }
}
