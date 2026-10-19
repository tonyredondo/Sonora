import AVFAudio
import Observation
import SFBAudioEngine
import SonoraCore

struct EqualizerSettings: Codable, Equatable {
    static let frequencies: [Float] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    var enabled = false
    var gains = Array(repeating: Float(0), count: 10)
    var preamp: Float = 0

    func validated() -> Self {
        var result = self
        result.gains = Self.frequencies.indices.map { index in
            guard gains.indices.contains(index), gains[index].isFinite else { return 0 }
            return min(12, max(-12, gains[index]))
        }
        result.preamp = preamp.isFinite ? min(12, max(-24, preamp)) : 0
        return result
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat, bass, vocals, rock, jazz, classical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: "Plano"
        case .bass: "Graves"
        case .vocals: "Voces"
        case .rock: "Rock"
        case .jazz: "Jazz"
        case .classical: "Clásica"
        }
    }
    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 3, 1, 0, 0, 0, -1, -1, -1]
        case .vocals: [-3, -2, -1, 0, 2, 4, 4, 2, 0, -1]
        case .rock: [4, 3, 1, -1, -2, 1, 3, 4, 4, 3]
        case .jazz: [3, 2, 1, 0, -1, 1, 2, 3, 3, 2]
        case .classical: [3, 2, 1, 0, -1, 0, 1, 2, 3, 3]
        }
    }
    // Leave output margin for the overlapping filters in these built-in curves.
    var preamp: Float { self == .flat ? 0 : -(gains.max() ?? 0) - 2 }
}

/// SFB serializes graph changes and this processor through its engine mutex.
/// The render callback never reads app state or takes a Swift lock.
final class EqualizerProcessor: @unchecked Sendable {
    let node = AVAudioUnitEQ(numberOfBands: 10)
    let timePitch = AVAudioUnitTimePitch()

    func applyPlayback(_ value: PlaybackAdjustment) {
        let value = value.validated
        timePitch.rate = value.rate
        timePitch.pitch = value.semitones * 100
        timePitch.bypass = value.isOriginal
    }
    private var settings = EqualizerSettings()
    private var sampleRate: Double = 44100

    func apply(_ settings: EqualizerSettings) {
        self.settings = settings
        node.bypass = !settings.enabled
        node.globalGain = settings.enabled ? settings.preamp : 0
        for index in node.bands.indices {
            let band = node.bands[index], frequency = EqualizerSettings.frequencies[index]
            let highest = max(20, Float(sampleRate / 2) - 1)
            band.filterType = .parametric
            band.frequency = min(frequency, highest)
            band.bandwidth = 1
            band.gain = settings.gains[index]
            band.bypass = frequency >= highest
        }
    }

    func connect(in engine: AVAudioEngine, format: AVAudioFormat) -> AVAudioNode {
        sampleRate = format.sampleRate
        apply(settings)
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        return node
    }
}

@MainActor @Observable
final class AudioEqualizer {
    private(set) var settings: EqualizerSettings
    private(set) var playback: PlaybackAdjustment
    @ObservationIgnored let processor = EqualizerProcessor()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let player: AudioPlayer

    init(defaults: UserDefaults, player: AudioPlayer) {
        self.defaults = defaults; self.player = player
        settings = defaults.data(forKey: "equalizerSettings")
            .flatMap { try? JSONDecoder().decode(EqualizerSettings.self, from: $0) }?.validated() ?? EqualizerSettings()
        playback = defaults.data(forKey: "playbackAdjustment")
            .flatMap { try? JSONDecoder().decode(PlaybackAdjustment.self, from: $0) }?.validated ?? PlaybackAdjustment()
        let processor = processor, settings = settings, playback = playback
        player.modifyProcessingGraph { engine in
            engine.attach(processor.node)
            engine.attach(processor.timePitch)
            processor.applyPlayback(playback)
            let source = player.sourceNode, format = source.outputFormat(forBus: 0)
            engine.disconnectNodeOutput(source)
            processor.apply(settings)
            let node = processor.connect(in: engine, format: format)
            engine.connect(source, to: node, format: format)
        }
    }

    func setPlayback(_ value: PlaybackAdjustment) {
        let value = value.validated
        guard value != playback else { return }
        playback = value
        let processor = processor
        player.modifyProcessingGraph { _ in processor.applyPlayback(value) }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "playbackAdjustment") }
    }

    var preset: EqualizerPreset? {
        EqualizerPreset.allCases.first { $0.gains == settings.gains && $0.preamp == settings.preamp }
    }
    func setEnabled(_ enabled: Bool) { var value = settings; value.enabled = enabled; update(value) }
    func select(_ preset: EqualizerPreset) {
        var value = settings; value.gains = preset.gains; value.preamp = preset.preamp; update(value)
    }
    func setGain(_ index: Int, to gain: Float) {
        guard settings.gains.indices.contains(index), gain.isFinite else { return }
        var value = settings; value.gains[index] = (gain * 2).rounded() / 2; update(value)
    }
    func setPreamp(_ gain: Float) {
        guard gain.isFinite else { return }
        var value = settings; value.preamp = (gain * 2).rounded() / 2; update(value)
    }
    private func update(_ value: EqualizerSettings) {
        let value = value.validated()
        guard value != settings else { return }
        settings = value
        let processor = processor
        player.modifyProcessingGraph { _ in processor.apply(value) }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "equalizerSettings") }
    }
}
