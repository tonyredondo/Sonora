import Foundation

public struct BeatGrid: Sendable, Equatable {
    public let period: Double
    public let anchor: Double
    public let confidence: Double
    public var bpm: Double { 60 / period }
    public init(period: Double, anchor: Double, confidence: Double) { self.period = period; self.anchor = anchor; self.confidence = confidence }
    public func nextBeat(at time: Double) -> Double { anchor + max(0, ceil((time - anchor - 0.000001) / period)) * period }
}

public enum RhythmAnalyzer {
    /// Offbeats can cancel the fundamental in the strict estimator. Once a tempo
    /// is available, emphasize stronger attacks to estimate a usable beat phase.
    public static func estimateForMixing(energy: [Double], hop: Double = 0.01, start: Double = 0) -> BeatGrid? {
        guard start.isFinite else { return nil }
        if let grid = estimate(energy: energy, hop: hop, start: start) { return grid }
        let tempo = TempoEstimate.estimate(energy: energy, hop: hop)
        guard let bpm = tempo.bpm else { return nil }
        let period = 60 / bpm
        let onsets = energy.indices.map { max(0, energy[$0] - ($0 == 0 ? 0 : energy[$0 - 1])) }
        guard let peak = onsets.max(), peak > 0.00001 else { return nil }
        var real = 0.0, imaginary = 0.0, total = 0.0
        for i in onsets.indices where onsets[i] >= peak * 0.1 {
            let weight = pow(onsets[i] / peak, 2), phase = 2 * .pi * Double(i) * hop / period
            real += weight * cos(phase); imaginary += weight * sin(phase); total += weight
        }
        let concentration = hypot(real, imaginary) / max(total, 0.000001)
        let confidence = min(0.7, sqrt(tempo.confidence * concentration))
        guard concentration >= 0.2, confidence >= 0.35,
              let first = onsets.firstIndex(where: { $0 >= peak * 0.25 }) else { return nil }
        var phase = atan2(imaginary, real) / (2 * .pi) * period
        if phase < 0 { phase += period }
        let anchor = start + phase + ((Double(first) * hop - phase) / period).rounded() * period
        return BeatGrid(period: period, anchor: anchor, confidence: confidence)
    }

    /// Positive changes in 10 ms RMS energy, not raw waveform correlation. A weak
    /// or ambiguous pulse is rejected; neither tempo nor phase is invented.
    public static func estimate(energy: [Double], hop: Double = 0.01, start: Double = 0) -> BeatGrid? {
        guard hop.isFinite, (0.005...0.02).contains(hop), start.isFinite,
              energy.count >= Int(6 / hop), energy.count <= 4000,
              energy.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        var onsets = [Double](repeating: 0, count: energy.count)
        for i in energy.indices { onsets[i] = max(0, energy[i] - (i == 0 ? 0 : energy[i - 1])) }
        let peak = onsets.max() ?? 0
        guard peak > 0.00001 else { return nil }
        onsets = onsets.map { $0 < peak * 0.08 ? 0 : $0 }
        guard onsets.filter({ $0 > peak * 0.25 }).count >= 6 else { return nil }
        let lower = Int((60 / 180.0 / hop).rounded(.down)), upper = Int((60 / 60.0 / hop).rounded(.up))
        func correlation(_ lag: Int) -> Double {
            var cross = 0.0, a = 0.0, b = 0.0
            for i in lag..<onsets.count {
                let x = onsets[i], y = onsets[i - lag]
                cross += x * y; a += x * x; b += y * y
            }
            return a * b > 0 ? cross / sqrt(a * b) : 0
        }
        let scores = (max(1, lower - 1)...(upper + 1)).map(correlation)
        let firstLag = max(1, lower - 1)
        var best: (period: Double, phase: Double, confidence: Double, score: Double)?
        for lag in lower...upper {
            let i = lag - firstLag, score = scores[i]
            guard score >= 0.55, score >= scores[max(0, i - 1)], score >= scores[min(scores.count - 1, i + 1)] else { continue }
            let before = scores[max(0, i - 1)], after = scores[min(scores.count - 1, i + 1)]
            let denominator = before - 2 * score + after
            let correction = abs(denominator) > 0.00001 ? min(0.5, max(-0.5, 0.5 * (before - after) / denominator)) : 0
            let period = (Double(lag) + correction) * hop
            var real = 0.0, imaginary = 0.0, weight = 0.0
            for j in onsets.indices where onsets[j] > 0 {
                let phase = 2 * .pi * Double(j) * hop / period
                real += onsets[j] * cos(phase); imaginary += onsets[j] * sin(phase); weight += onsets[j]
            }
            let concentration = hypot(real, imaginary) / max(weight, 0.000001)
            let confidence = sqrt(score * concentration)
            guard concentration >= 0.65, confidence >= 0.72 else { continue }
            var phase = atan2(imaginary, real) / (2 * .pi) * period
            if phase < 0 { phase += period }
            // Prefer a clearer pulse. For equally strong metrical alternatives,
            // prefer the tempo nearest 120 BPM rather than arbitrary iteration order.
            let ranked = confidence - 0.015 * abs(log2((60 / period) / 120))
            if best == nil || ranked > best!.score { best = (period, phase, confidence, ranked) }
        }
        guard let best, let first = onsets.firstIndex(where: { $0 > peak * 0.25 }) else { return nil }
        let firstTime = Double(first) * hop
        let anchor = start + best.phase + ((firstTime - best.phase) / best.period).rounded() * best.period
        return BeatGrid(period: best.period, anchor: anchor, confidence: best.confidence)
    }
}

public struct AdaptiveMixPlan: Sendable, Equatable {
    public let fadeStart: Double
    public let duration: Double
    public let incomingSkip: Double
    public let bpm: Double
}
public enum AdaptiveMixDecision: Sendable, Equatable {
    case matched(AdaptiveMixPlan)
    case fallback(String)
}
public enum AdaptiveMixPlanner {
    /// A reference tempo can shape the fade even when beat phase is uncertain.
    /// Prefer the outgoing tempo; never skip the incoming intro or claim alignment.
    public static func estimated(outgoingBPM: Double?, incomingBPM: Double?, end: Double,
                                 earliestStart: Double, incomingPosition: Double,
                                 incomingDuration: Double, maximumOverlap: Double) -> AdaptiveMixPlan? {
        guard [end, earliestStart, incomingPosition, incomingDuration, maximumOverlap].allSatisfy(\.isFinite),
              earliestStart >= 0, incomingPosition >= 0,
              let bpm = [outgoingBPM, incomingBPM].compactMap({ $0 })
                .first(where: { $0.isFinite && (40...300).contains($0) }) else { return nil }
        let maximum = min(12, maximumOverlap, end - earliestStart, (incomingDuration - incomingPosition) / 2)
        guard maximum > 0 else { return nil }
        let period = 60 / bpm, beats = floor(maximum / period)
        let duration = beats >= 1 ? beats * period : maximum
        return AdaptiveMixPlan(fadeStart: end - duration, duration: duration, incomingSkip: 0, bpm: bpm)
    }

    public static func plan(outgoing: BeatGrid?, incoming: BeatGrid?, end: Double, earliestStart: Double,
                            incomingPosition: Double, incomingDuration: Double, maximumOverlap: Double) -> AdaptiveMixDecision {
        guard let outgoing, let incoming, outgoing.confidence.isFinite, incoming.confidence.isFinite,
              outgoing.confidence >= 0.35, incoming.confidence >= 0.35,
              outgoing.period.isFinite, incoming.period.isFinite, (0.2...1.5).contains(outgoing.period), (0.2...1.5).contains(incoming.period),
              outgoing.anchor.isFinite, incoming.anchor.isFinite,
              [end, earliestStart, incomingPosition, incomingDuration, maximumOverlap].allSatisfy(\.isFinite) else {
            return .fallback("No se detectó un pulso estable en ambas canciones.")
        }
        let cue = incoming.nextBeat(at: incomingPosition), skip = max(0, cue - incomingPosition)
        guard skip <= 1, skip <= incoming.period * 2 else { return .fallback("La introducción no permite alinear el pulso sin recortarla demasiado.") }
        // Estimated phases tolerate small timing differences. Shorten the overlap
        // to bound drift instead of rejecting every pair below strict confidence.
        let approximate = min(outgoing.confidence, incoming.confidence) < 0.72
        let allowedDrift = approximate ? min(0.1, outgoing.period * 0.15) : 0.035
        let difference = abs(outgoing.period - incoming.period)
        let driftLimit = difference < 0.000001 ? maximumOverlap : allowedDrift * outgoing.period / difference
        let maximum = min(12, maximumOverlap, driftLimit, max(0, (incomingDuration - cue) / 2))
        let start = outgoing.nextBeat(at: max(earliestStart, end - maximum))
        let duration = end - start
        guard duration >= outgoing.period * (approximate ? 2 : 4), duration <= maximum + 0.000001 else {
            return .fallback("Los ritmos difieren demasiado o no dejan suficientes pulsos para mezclar.")
        }
        return .matched(AdaptiveMixPlan(fadeStart: start, duration: duration, incomingSkip: skip, bpm: outgoing.bpm))
    }
}
