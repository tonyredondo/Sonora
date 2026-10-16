import AVFAudio
import SFBAudioEngine

/// Crossfade uses 48 kHz stereo; ReplayGain uses float at the original rate/layout.
/// Conversion, gain and disk reads
/// run on the decoder worker, never the audio render callback. The two scratch
/// buffers are fixed-size regardless of file length; original files are untouched.
final class NormalizedPCMDecoder: NSObject, PCMDecoding {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private let base: any PCMDecoding
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let converted: AVAudioPCMBuffer
    private let gain: Float
    private let balance: Float
    private var readOffset = 0
    private var ended = false
    private(set) var position: AVAudioFramePosition
    let length: AVAudioFramePosition
    let processingFormat: AVAudioFormat
    var inputSource: InputSource { base.inputSource }
    var sourceFormat: AVAudioFormat { base.sourceFormat }
    var decodingIsLossless: Bool { false }
    var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    var isOpen: Bool { base.isOpen }
    // The controller reopens at a source position for seek/queue edits. Direct seeks
    // would invalidate both the converter's buffered frames and the overlap plan.
    let supportsSeeking = false

    init(_ base: any PCMDecoding, format: AVAudioFormat = NormalizedPCMDecoder.format, gain: Double = 1, balance: Float = 0) throws {
        guard base.length > 0,
              gain.isFinite, gain >= 0, balance.isFinite, (-1...1).contains(balance),
              let converter = AVAudioConverter(from: base.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: base.processingFormat, frameCapacity: 8192),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.base = base; self.converter = converter; self.input = input; self.converted = converted
        processingFormat = format; self.gain = Float(gain); self.balance = balance
        let ratio = format.sampleRate / base.processingFormat.sampleRate
        length = AVAudioFramePosition((Double(base.length) * ratio).rounded())
        position = AVAudioFramePosition((Double(max(0, base.position)) * ratio).rounded())
        // File conversion must compensate the resampler's delay. `.none` adds
        // leading latency and trailing frames, shifting the overlap and playhead.
        converter.primeMethod = .normal
        super.init()
    }
    func open() throws { if !base.isOpen { try base.open() } }
    func close() throws { try base.close() }
    func seek(to frame: AVAudioFramePosition) throws { throw CocoaError(.featureUnsupported) }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let buffer = buffer as? AVAudioPCMBuffer else { throw CocoaError(.fileReadCorruptFile) }
        try decode(into: buffer, length: buffer.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length requested: AVAudioFrameCount) throws {
        guard buffer.format == processingFormat, let destination = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let wanted = min(Int(min(requested, buffer.frameCapacity)), Int(max(0, length - position)))
        var written = 0
        while written < wanted {
            if readOffset == Int(converted.frameLength) {
                guard !ended else { break }
                try convertNextBuffer()
                if converted.frameLength == 0 { break }
            }
            let count = min(wanted - written, Int(converted.frameLength) - readOffset)
            // AVAudioMixerNode uses equal-power panning for a mono input. Preserve
            // that level when the converter duplicates mono into two channels.
            let gain = self.gain * (base.processingFormat.channelCount == 1 && processingFormat.channelCount == 2 ? Float(1 / sqrt(2.0)) : 1)
            for channel in 0..<Int(processingFormat.channelCount) {
                let source = converted.floatChannelData![channel] + readOffset
                let scale = gain * (processingFormat.channelCount == 2 ? (channel == 0 ? 1 - max(0, balance) : 1 + min(0, balance)) : 1)
                if scale == 1 { (destination[channel] + written).update(from: source, count: count) }
                else { for frame in 0..<count { destination[channel][written + frame] = source[frame] * scale } }
            }
            readOffset += count; written += count
        }
        // A provider/file may be truncated after it was opened. Do not silently
        // treat a missing tail as a successful transition. Allow one rounding frame.
        if written < wanted && position + AVAudioFramePosition(written) < length - 1 {
            throw CocoaError(.fileReadCorruptFile)
        }
        buffer.frameLength = AVAudioFrameCount(written)
        position += AVAudioFramePosition(written)
    }
    private func convertNextBuffer() throws {
        readOffset = 0; converted.frameLength = 0
        var conversionError: NSError?, readError: Error?
        let status = converter.convert(to: converted, error: &conversionError) { [self] requested, state in
            do {
                try base.decode(into: input, length: min(requested, input.frameCapacity))
                state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                return input.frameLength == 0 ? nil : input
            } catch {
                readError = error; state.pointee = .endOfStream; return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .error { throw CocoaError(.fileReadCorruptFile) }
        ended = status == .endOfStream || converted.frameLength == 0
    }
}
