import AVFAudio
import Accelerate
import SFBAudioEngine
import SonoraCore

struct AudioRhythmAnalysis: Sendable {
    let head: BeatGrid?
    let tail: BeatGrid?
    let headBPM: Double?
    let tailBPM: Double?
    let reason: String?
    let milliseconds: Double
    static func unavailable(_ reason: String) -> Self { Self(head: nil, tail: nil, headBPM: nil, tailBPM: nil, reason: reason, milliseconds: 0) }
}

enum AudioRhythmAnalyzer {
    private enum Limit: Error { case reached }
    /// At most two eight-second windows, fixed-size PCM buffers and 500 ms of
    /// analysis work. This runs inside coordinated I/O, never on the render thread.
    static func analyze(_ url: URL, cue: CueSegment? = nil) throws -> AudioRhythmAnalysis {
        let clock = ContinuousClock(), start = clock.now, deadline = start.advanced(by: .milliseconds(500))
        func elapsed() -> Double {
            let value = start.duration(to: clock.now).components
            return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        }
        do {
            let probe = try AudioDecoders.open(url, cue: cue)
            let duration = Double(max(0, probe.length)) / probe.processingFormat.sampleRate, seeking = probe.supportsSeeking
            try probe.close()
            guard duration >= 8, seeking else { return .unavailable("La canción es demasiado breve o no permite analizar su final.") }
            func window(_ seconds: Double) throws -> (grid: BeatGrid?, bpm: Double?) {
                try Task.checkCancellation()
                let source = try AudioDecoders.open(url, cue: cue)
                defer { try? source.close() }
                if seconds > 0 { try source.seek(to: AVAudioFramePosition(seconds * source.processingFormat.sampleRate)) }
                let actualStart = Double(max(0, source.position)) / source.processingFormat.sampleRate
                let decoder = try NormalizedPCMDecoder(source)
                let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192)!
                var remaining = min(384000, Int(decoder.length - decoder.position))
                var energy: [Double] = [], sum = 0.0, count = 0
                energy.reserveCapacity(800)
                while remaining > 0 {
                    try Task.checkCancellation()
                    guard clock.now < deadline else { throw Limit.reached }
                    try decoder.decode(into: buffer, length: AVAudioFrameCount(min(8192, remaining)))
                    guard buffer.frameLength > 0 else { break }
                    let data = buffer.floatChannelData!
                    var offset = 0
                    while offset < Int(buffer.frameLength) {
                        let frames = min(480 - count, Int(buffer.frameLength) - offset)
                        var left: Float = 0, right: Float = 0
                        vDSP_svesq(data[0] + offset, 1, &left, vDSP_Length(frames))
                        vDSP_svesq(data[1] + offset, 1, &right, vDSP_Length(frames))
                        sum += Double(left + right) / 2; count += frames; offset += frames
                        if count == 480 { energy.append(sqrt(sum / 480)); sum = 0; count = 0 }
                    }
                    remaining -= Int(buffer.frameLength)
                }
                let grid = RhythmAnalyzer.estimateForMixing(energy: energy, start: actualStart)
                return (grid, grid?.bpm ?? TempoEstimate.estimate(energy: energy).bpm)
            }
            let head = try window(0), tail = try window(max(0, duration - 8))
            return AudioRhythmAnalysis(head: head.grid, tail: tail.grid, headBPM: head.bpm, tailBPM: tail.bpm,
                reason: head.grid == nil || tail.grid == nil ? "No se detectó un pulso estable." : nil, milliseconds: elapsed())
        } catch is CancellationError { throw CancellationError() }
        catch {
            return AudioRhythmAnalysis(head: nil, tail: nil, headBPM: nil, tailBPM: nil,
                reason: error is Limit ? "El análisis alcanzó su límite de tiempo." : "No se pudo analizar el ritmo.", milliseconds: elapsed())
        }
    }
}
