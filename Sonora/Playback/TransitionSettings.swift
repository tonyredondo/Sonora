import Foundation

enum TransitionMode: String, Codable, CaseIterable, Identifiable {
    case continuous, crossfade, adaptive
    var id: Self { self }
    var title: String { switch self { case .continuous: "Continua"; case .crossfade: "Crossfade"; case .adaptive: "Mezcla automática (beta)" } }
}

struct TransitionSettings: Codable, Equatable {
    var mode: TransitionMode = .continuous
    var duration: Double = 5

    var validated: Self {
        Self(mode: mode, duration: duration.isFinite ? min(12, max(1, duration.rounded())) : 5)
    }
}

enum TransitionOutcome: Sendable {
    case mixed(Double), notReady, tooShort, incompatible, sourceFailed, failed(String)
    case adaptive(Double, Double), adaptiveEstimate(Double, Double), estimated(Double, Double), adaptiveFallback(String)

    var description: String {
        switch self {
        case .mixed(let seconds): String(format: "Fundido de %.1f s", seconds)
        case .notReady: "Continua: la siguiente pista no estaba preparada."
        case .tooShort: "Continua: la pista era demasiado breve para el fundido."
        case .incompatible: "Continua: no se pudo mezclar este formato."
        case .sourceFailed: "Continua tras un error de lectura."
        case .failed(let message): message
        case .adaptive(let seconds, let bpm): String(format: "Mezcla alineada a %.0f BPM · %.1f s", bpm.rounded(), seconds)
        case .adaptiveEstimate(let seconds, let bpm): String(format: "Mezcla alineada por estimación · %.0f BPM · %.1f s", bpm.rounded(), seconds)
        case .estimated(let seconds, let bpm): String(format: "Fundido con tempo estimado de %.0f BPM · %.1f s", bpm.rounded(), seconds)
        case .adaptiveFallback(let reason): "Crossfade: " + reason
        }
    }
}
