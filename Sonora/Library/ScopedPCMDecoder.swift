import AVFAudio
import SFBAudioEngine

/// The engine retains this wrapper for exactly as long as it can read the source.
/// Queued decoders can be discarded without a delegate callback, so the access
/// lifetime must follow the decoder itself rather than the UI's event dictionary.
final class ScopedPCMDecoder: NSObject, PCMDecoding {
    private let base: any PCMDecoding
    private let folder: ScopedFolder
    init(_ base: any PCMDecoding, folder: ScopedFolder) { self.base = base; self.folder = folder }
    var inputSource: InputSource { base.inputSource }
    var sourceFormat: AVAudioFormat { base.sourceFormat }
    var processingFormat: AVAudioFormat { base.processingFormat }
    var decodingIsLossless: Bool { base.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    var isOpen: Bool { base.isOpen }
    var supportsSeeking: Bool { base.supportsSeeking }
    var position: AVAudioFramePosition { base.position }
    var length: AVAudioFramePosition { base.length }
    func open() throws { try base.open() }
    func close() throws { try base.close() }
    func decode(into buffer: AVAudioBuffer) throws { try base.decode(into: buffer) }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws { try base.decode(into: buffer, length: length) }
    func seek(to frame: AVAudioFramePosition) throws { try base.seek(to: frame) }
}
