import Foundation

enum NormalizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, track, album
    var id: Self { self }
    var title: String { switch self { case .off: "Desactivada"; case .track: "Por canción"; case .album: "Por álbum" } }
}

struct ListeningSettings: Codable, Equatable {
    var normalization: NormalizationMode = .off
    var balance: Float = 0
    var validated: Self { Self(normalization: normalization, balance: balance.isFinite ? min(1, max(-1, balance)) : 0) }
}

struct ReplayGain: Sendable {
    var trackGain: Double? = nil
    var trackPeak: Double? = nil
    var albumGain: Double? = nil
    var albumPeak: Double? = nil
    func multiplier(for mode: NormalizationMode) -> Double {
        guard mode != .off else { return 1 }
        let gain = mode == .album ? albumGain : trackGain
        let peak = mode == .album ? albumPeak : trackPeak
        guard let gain, gain.isFinite else { return 1 }
        var value = pow(10, min(20, max(-60, gain)) / 20)
        if let peak, peak.isFinite, peak > 0 { value = min(value, 1 / peak) }
        return value
    }
}

enum SleepTimer: Codable, Equatable {
    case deadline(Date)
    case endOfTrack(String)
}
