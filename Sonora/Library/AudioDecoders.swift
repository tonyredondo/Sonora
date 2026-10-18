import AVFAudio
import SFBAudioEngine
import SonoraCore

enum AudioDecoders {
    /// Preserve all lossless source precision when deriving a content identity.
    static func openForIdentity(_ url: URL, cue: CueSegment? = nil) throws -> any PCMDecoding {
        let decoder = try openFile(url, nativeFormat: .pcmFormatFloat64)
        if let cue { return try CuePCMDecoder(decoder, segment: cue) }
        return decoder
    }
    static func open(_ url: URL, cue: CueSegment? = nil) throws -> any PCMDecoding {
        let decoder = try openFile(url)
        if let cue { return try CuePCMDecoder(decoder, segment: cue) }
        return decoder
    }
    private static func openFile(_ url: URL, nativeFormat: AVAudioCommonFormat = .pcmFormatFloat32) throws -> any PCMDecoding {
        // SFB 0.14's Core Audio callback reports EOF while probing valid short M4A
        // files. Read Apple containers directly, preserving the same PCM player.
        if ["m4a", "mp4", "aac", "caf"].contains(url.pathExtension.lowercased()) {
            return try NativeFileDecoder(url: url, commonFormat: nativeFormat)
        }
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        return decoder
    }
}

/// Exclusive ownership passes to SFBAudioPlayer after enqueue, as for its decoders.
private final class NativeFileDecoder: NSObject, PCMDecoding {
    let inputSource: InputSource
    let sourceFormat: AVAudioFormat
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    let decodingIsLossless: Bool
    let properties: [AudioDecodingPropertiesKey: Any] = [:]
    let supportsSeeking = true
    private let url: URL
    private var file: AVAudioFile?
    var position: AVAudioFramePosition { file?.framePosition ?? 0 }
    var isOpen: Bool { file != nil }

    init(url: URL, commonFormat: AVAudioCommonFormat = .pcmFormatFloat32) throws {
        var file = try AVAudioFile(forReading: url, commonFormat: commonFormat, interleaved: false)
        if commonFormat == .pcmFormatFloat64, file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless {
            // Content identity preserves ALAC's integer source precision.
            file = try AVAudioFile(forReading:url,commonFormat:.pcmFormatInt32,interleaved:false)
        }
        self.url = url
        self.file = file
        inputSource = try InputSource(for: url)
        sourceFormat = file.fileFormat
        processingFormat = file.processingFormat
        length = file.length
        decodingIsLossless = [kAudioFormatLinearPCM, kAudioFormatAppleLossless].contains(file.fileFormat.streamDescription.pointee.mFormatID)
        super.init()
    }
    func open() throws { if file == nil { file = try AVAudioFile(forReading: url, commonFormat: processingFormat.commonFormat, interleaved: processingFormat.isInterleaved) } }
    func close() throws { file = nil }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let buffer = buffer as? AVAudioPCMBuffer else { throw CocoaError(.fileReadCorruptFile) }
        try decode(into: buffer, length: buffer.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        guard let file else { throw CocoaError(.fileReadNoSuchFile) }
        let remaining = file.length - file.framePosition
        // AVAudioFile can report eofErr for AAC when a converter asks for another
        // buffer after the last frame. PCMDecoding requires an empty successful read.
        guard remaining > 0 else { buffer.frameLength = 0; return }
        let count = AVAudioFrameCount(min(AVAudioFramePosition(min(length, buffer.frameCapacity)), remaining))
        try file.read(into: buffer, frameCount: count)
    }
    func seek(to frame: AVAudioFramePosition) throws {
        guard let file, frame >= 0, frame <= length else { throw CocoaError(.fileReadCorruptFile) }
        file.framePosition = frame
    }
}
