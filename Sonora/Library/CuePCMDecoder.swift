import AVFAudio
import SFBAudioEngine
import SonoraCore

/// Presents one CUE interval as an independent seekable stream. Consecutive
/// intervals round the same CD boundary to the same PCM frame.
final class CuePCMDecoder: NSObject, PCMDecoding {
    private let base: any PCMDecoding
    private let start: AVAudioFramePosition
    let length: AVAudioFramePosition
    init(_ base: any PCMDecoding, segment: CueSegment) throws {
        let rate = base.processingFormat.sampleRate
        let start = AVAudioFramePosition((segment.startSeconds * rate).rounded())
        let end = segment.endSeconds.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? base.length
        guard segment.isValid, base.supportsSeeking, start >= 0, end > start, end <= base.length else {
            throw MusicTextError.invalid("Los índices CUE quedan fuera del audio o el formato no permite buscar posiciones.")
        }
        self.base = base; self.start = start; length = end - start
        super.init()
        try base.seek(to: start)
    }
    var inputSource: InputSource { base.inputSource }
    var sourceFormat: AVAudioFormat { base.sourceFormat }
    var processingFormat: AVAudioFormat { base.processingFormat }
    var decodingIsLossless: Bool { base.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    var isOpen: Bool { base.isOpen }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { max(0, min(length, base.position - start)) }
    func open() throws { if !base.isOpen { try base.open(); try base.seek(to: start) } }
    func close() throws { try base.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let buffer = buffer as? AVAudioPCMBuffer else { throw CocoaError(.fileReadCorruptFile) }
        try decode(into: buffer, length: buffer.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length requested: AVAudioFrameCount) throws {
        let count = min(AVAudioFramePosition(min(requested, buffer.frameCapacity)), length - position)
        guard count > 0 else { buffer.frameLength = 0; return }
        try base.decode(into: buffer, length: AVAudioFrameCount(count))
        guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
    func seek(to frame: AVAudioFramePosition) throws {
        guard frame >= 0, frame <= length else { throw CocoaError(.fileReadCorruptFile) }
        try base.seek(to: start + frame)
    }
}
