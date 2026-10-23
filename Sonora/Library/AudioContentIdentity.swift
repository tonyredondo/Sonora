import AVFAudio
import CryptoKit
import SonoraCore

/// Exact decoded samples, not an acoustic fingerprint: no resampling, downmixing or tag bytes.
/// Float64 preserves Float32 and all supported integer PCM precision. The version, rate,
/// channel layout and frame count are part of the digest. Buffers have a fixed memory bound.
enum AudioContentIdentity {
    static func read(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) async throws -> String {
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
            let source = try AudioDecoders.openForIdentity(url, cue: track.cue)
            defer { try? source.close() }
            let original = source.processingFormat, channels = Int(original.channelCount)
            guard original.sampleRate.isFinite, original.sampleRate > 0, channels > 0, channels <= 32,
                  source.length > 0, Double(source.length) / original.sampleRate <= 86400 else { throw CocoaError(.fileReadCorruptFile) }
            let layout = try IdentityPCMLayout(original)
            guard let input = AVAudioPCMBuffer(pcmFormat: original, frameCapacity: 8192) else { throw CocoaError(.fileReadUnsupportedScheme) }
            var hash = SHA256()
            hash.update(data: Data("Sonora pcm64-v1\0".utf8))
            func append<T: FixedWidthInteger>(_ number: T) {
                var little = number.littleEndian
                withUnsafeBytes(of: &little) { hash.update(bufferPointer: $0) }
            }
            append(original.sampleRate.bitPattern); append(UInt32(channels)); append(UInt64(source.length))
            // Standard mono/stereo have a canonical order. Keep other layouts,
            // including two-channel mid/side, distinct from ordinary stereo.
            if let layout = original.channelLayout,
               channels > 2 || layout.layout.pointee.mChannelLayoutTag != (channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo) {
                let value = layout.layout.pointee
                guard value.mNumberChannelDescriptions <= 32 else { throw CocoaError(.fileReadCorruptFile) }
                append(value.mChannelLayoutTag); append(value.mChannelBitmap.rawValue); append(value.mNumberChannelDescriptions)
                guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { throw CocoaError(.fileReadCorruptFile) }
                let first = UnsafeRawPointer(layout.layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
                let descriptions = UnsafeBufferPointer(start: first, count: Int(value.mNumberChannelDescriptions))
                for description in descriptions {
                    append(description.mChannelLabel); append(description.mChannelFlags.rawValue)
                    if !description.mChannelFlags.intersection([.rectangularCoordinates,.sphericalCoordinates]).isEmpty {
                        append(description.mCoordinates.0.bitPattern); append(description.mCoordinates.1.bitPattern); append(description.mCoordinates.2.bitPattern)
                    } else { append(UInt32(0)); append(UInt32(0)); append(UInt32(0)) }
                }
            } else { append(UInt32(0)) }
            var samples = [UInt64](repeating: 0, count: 8192 * channels), frames: Int64 = 0
            while true {
                try Task.checkCancellation()
                try source.decode(into: input, length: input.frameCapacity)
                let count = Int(input.frameLength), buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                if count == 0 { break }
                guard buffers.count >= (layout.interleaved ? 1 : channels) else { throw CocoaError(.fileReadCorruptFile) }
                for channel in 0..<channels {
                    let buffer = buffers[layout.interleaved ? 0 : channel]
                    guard let data = buffer.mData, Int(buffer.mDataByteSize) >= count * layout.frameBytes else { throw CocoaError(.fileReadCorruptFile) }
                    for frame in 0..<count {
                        let offset = frame * layout.frameBytes + (layout.interleaved ? channel * layout.sampleBytes : 0)
                        let value = layout.value(data, offset: offset)
                        guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                        samples[frame * channels + channel] = (value == 0 ? 0.0 : value).bitPattern.littleEndian
                    }
                }
                samples.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count * channels * 8))) }
                frames += Int64(count)
                guard frames <= source.length else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard frames == source.length else { throw CocoaError(.fileReadCorruptFile) }
            return "pcm64-v1:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// The identity protocol defines sample precision, integer alignment and byte order
/// explicitly, independently of playback converters and their processing formats.
// Lossless CUE export shares this reader to handle integer alignment and byte
// order without reducing sample precision.
struct IdentityPCMLayout {
    let interleaved: Bool
    let frameBytes: Int
    let sampleBytes: Int
    private let bits: Int
    private let floating: Bool
    private let signed: Bool
    private let bigEndian: Bool
    private let alignedHigh: Bool
    init(_ format: AVAudioFormat) throws {
        let value = format.streamDescription.pointee
        interleaved = value.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        frameBytes = Int(value.mBytesPerFrame)
        sampleBytes = frameBytes / (interleaved ? Int(value.mChannelsPerFrame) : 1)
        bits = Int(value.mBitsPerChannel)
        floating = value.mFormatFlags & kAudioFormatFlagIsFloat != 0
        signed = value.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        bigEndian = value.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        alignedHigh = value.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        guard value.mFormatID == kAudioFormatLinearPCM, [1,2,3,4,8].contains(sampleBytes),
              frameBytes == sampleBytes * (interleaved ? Int(value.mChannelsPerFrame) : 1), bits > 0, bits <= sampleBytes * 8,
              floating ? ([32,64].contains(bits) && sampleBytes * 8 == bits) : bits <= 32 else { throw CocoaError(.fileReadUnsupportedScheme) }
    }
    func value(_ data: UnsafeRawPointer, offset: Int) -> Double {
        var raw: UInt64
        switch sampleBytes {
        case 1: raw = UInt64(data.load(fromByteOffset: offset, as: UInt8.self))
        case 2:
            let value = data.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            raw = UInt64(bigEndian ? value.bigEndian : value.littleEndian)
        case 3:
            let a = UInt64(data.load(fromByteOffset: offset, as: UInt8.self)), b = UInt64(data.load(fromByteOffset: offset + 1, as: UInt8.self)), c = UInt64(data.load(fromByteOffset: offset + 2, as: UInt8.self))
            raw = bigEndian ? (a << 16 | b << 8 | c) : (c << 16 | b << 8 | a)
        case 4:
            let value = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            raw = UInt64(bigEndian ? value.bigEndian : value.littleEndian)
        default:
            let value = data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            raw = bigEndian ? value.bigEndian : value.littleEndian
        }
        if floating { return bits == 32 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw) }
        if alignedHigh { raw >>= sampleBytes * 8 - bits }
        raw &= (UInt64(1) << bits) - 1
        let midpoint = Int64(1) << (bits - 1)
        let integer = signed ? (Int64(raw) >= midpoint ? Int64(raw) - 2 * midpoint : Int64(raw)) : Int64(raw) - midpoint
        return Double(integer) / Double(midpoint)
    }
}
