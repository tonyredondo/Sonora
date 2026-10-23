import AVFAudio
import Foundation
import ImageIO
import lame
import SFBAudioEngine
import SonoraCore

enum PlaylistFolderExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case original, mp3
        var id: String { rawValue }
        var title: String { self == .original ? "Originales" : "MP3 · 320 kb/s" }
    }
    struct Progress: Sendable {
        let filename: String
        let completed: Int
        let total: Int
        let fraction: Double
    }
    @MainActor static func exportPlaylist(_ id: String, library: MusicLibrary, folder: URL, name: String, format: Format,
                                          interpretations: [String: PortableInterpretations] = [:],
                                          progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        guard let playlist = library.state.playlists.first(where: { $0.id == id }), !playlist.songIDs.isEmpty else {
            throw MusicTextError.invalid("La playlist está vacía o ya no existe.")
        }
        guard playlist.songIDs.count <= 10_000 else { throw MusicTextError.invalid("La lista supera las 10.000 canciones que admite M3U8.") }
        let songs = try playlist.songIDs.map { id in
            guard let song = library.state.songs[id], song.audioTrack != nil else {
                throw MusicTextError.invalid("Una canción ya no está en la biblioteca.")
            }
            return song
        }
        let scopes = try Dictionary(uniqueKeysWithValues: Set(songs.map(\.sourceID)).map { ($0, try library.access($0)) })
        let destination = try ScopedFolder(folder), job = FolderExportJob()
        let worker = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime((scopes, destination)) {} }
            do { return try job.export(songs, scopes: scopes, destination: destination.url, name: name, format: format, interpretations: interpretations, progress: progress) }
            catch { if Task.isCancelled { throw CancellationError() }; throw error }
        }
        // Once the final rename succeeds the export is committed, even if a
        // cancellation races with returning its URL. Never delete a published folder.
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            worker.cancel(); job.destination.cancel(); job.source.cancel(); job.lyrics.cancel()
        }
    }
}

private final class FolderExportJob: @unchecked Sendable {
    let destination = NSFileCoordinator()
    let source = NSFileCoordinator()
    let lyrics = NSFileCoordinator()

    func export(_ songs: [CollectionSong], scopes: [String: ScopedFolder], destination root: URL, name: String,
                format: PlaylistFolderExport.Format, interpretations: [String: PortableInterpretations], progress: @escaping @Sendable (PlaylistFolderExport.Progress) -> Void) throws -> URL {
        let stage = try write(in: root) { directory in
            try Task.checkCancellation()
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileWriteInvalidFileName) }
            let stage = directory.appendingPathComponent(".sonora-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            return stage
        }
        defer { try? FileManager.default.removeItem(at: stage) }
        var entries: [M3UEntry] = []
        let digits = max(2, String(songs.count).count)
        for (index, song) in songs.enumerated() {
            try Task.checkCancellation()
            guard let track = song.audioTrack, let folder = scopes[song.sourceID] else { throw CocoaError(.fileReadNoPermission) }
            let entry = try read(track: track, folder: folder) { url in
                let native = try metadata(at: url)
                let tags = track.tags(overriding: MetadataService.values(native))
                let title = tags[.title].flatMap { $0.isEmpty ? nil : $0 } ?? track.displayName
                let artist = tags[.artist].flatMap { $0.isEmpty ? nil : $0 }
                let ext = format == .mp3 ? "mp3" : track.cue == nil ? url.pathExtension.lowercased() : "wav"
                let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
                let filename = "\(number) - \(safeName([artist, title].compactMap { $0 }.joined(separator: " - "))).\(ext)"
                let output = stage.appendingPathComponent(filename)
                let report = ExportProgress(filename: filename, index: index, total: songs.count, callback: progress)
                report.update(0, force: true)
                var text = LyricsSource.read(for: url, embedded: native.lyrics ?? "", coordinator: lyrics).text
                let externalArt = native.attachedPictures.isEmpty ? LocalArtwork.data(for: url) : nil
                let converts = track.cue != nil || (format == .mp3 && url.pathExtension.lowercased() != "mp3")
                let id3Extras = converts && ["mp3", "wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) ? try ID3ExportTags.read(from: url) : [:]
                if converts {
                    let decoder = try AudioDecoders.openForIdentity(url, cue: track.cue)
                    defer { try? decoder.close() }
                    if let cue = track.cue, LyricsDocument(text: text).isTimed {
                        let sliced = LyricsDocument(text: text).sliced(from: cue.startSeconds, duration: Double(decoder.length) / decoder.processingFormat.sampleRate)
                        text = ([sliced.isAITranscribed ? LyricsDocument.aiTranscriptionMarker : nil,
                                 sliced.isAIRepaired ? LyricsDocument.aiRepairMarker : nil].compactMap { $0 } +
                                sliced.lines.map { LyricsDraft.timestamp($0.time ?? 0) + $0.text }).joined(separator: "\n")
                    }
                    if format == .mp3 { try mp3(decoder, to: output, progress: report) }
                    else { try wav(decoder, to: output, progress: report) }
                } else { try copy(url, to: output, progress: report) }
                if converts || text != (native.lyrics ?? "") || externalArt != nil {
                    if MetadataService.writableExtensions.contains(ext) {
                        let desired = AudioMetadata()
                        desired.copyMetadata(from: native); desired.copyAttachedPicturesFrom(native)
                        if converts {
                            apply(tags, to: desired)
                            desired.title = title
                        }
                        desired.lyrics = text.isEmpty ? nil : text
                        if let externalArt { desired.attachPicture(AttachedPicture(imageData: externalArt, type: .frontCover)) }
                        try save(desired, to: output, preserving: id3Extras, converted: converts)
                    } else if let externalArt {
                        // Raw AAC/CAF have no writable tag container in Sonora.
                        // Keep external artwork alongside their unchanged audio.
                        let imageType = CGImageSourceCreateWithData(externalArt as CFData, nil).flatMap { CGImageSourceGetType($0) }
                        let ext = imageType as String? == "public.png" ? "png" : "jpg"
                        try externalArt.write(to: output.deletingPathExtension().appendingPathExtension("cover").appendingPathExtension(ext), options: .withoutOverwriting)
                    }
                }
                if ext == "mp3", let reading = interpretations[song.id], !reading.isEmpty {
                    let context = LyricsInterpretationContext(title: title, artist: artist ?? "", album: tags[.album] ?? "")
                    let albumArtist = (tags[.albumArtist].flatMap { $0.isEmpty ? nil : $0 }) ?? (artist ?? "")
                    guard reading.songs.allSatisfy({ $0.value.matches(LyricsDocument(text: text), language: $0.key, context: context) }),
                          reading.albums.allSatisfy({ $0.value.matches(language: $0.key, title: tags[.album] ?? "", artist: albumArtist) }) else {
                        throw MetadataIOError.changed
                    }
                    let additional = try reading.tags()
                    try ID3ExportTags.write(additional, to: output)
                    let saved = try ID3ExportTags.read(from: output)
                    guard additional.allSatisfy({ saved[$0.key] == $0.value }) else { throw MetadataLookupError.invalidResponse }
                }
                if !text.isEmpty {
                    let sidecar = output.deletingPathExtension().appendingPathExtension(LyricsDocument(text: text).isTimed ? "lrc" : "txt")
                    try Data(text.utf8).write(to: sidecar, options: .withoutOverwriting)
                }
                try Task.checkCancellation()
                report.update(1, force: true)
                return M3UEntry(path: filename, title: title)
            }
            entries.append(entry)
        }
        let base = safeName(name)
        try M3UPlaylist(entries: entries).encoded().write(to: stage.appendingPathComponent(base).appendingPathExtension("m3u8"), options: .withoutOverwriting)
        return try write(in: root) { directory in
            try Task.checkCancellation()
            // Coordinate name selection and publication together. A failed move
            // cannot replace an existing directory, including a provider collision.
            for suffix in 1...1000 {
                let output = directory.appendingPathComponent(suffix == 1 ? base : "\(base) \(suffix)", isDirectory: true)
                if FileManager.default.fileExists(atPath: output.path) { continue }
                try FileManager.default.moveItem(at: stage, to: output)
                return output
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private func write<T>(in root: URL, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?, error: NSError?
        destination.coordinate(writingItemAt: root, options: [], error: &error) { directory in result = Result { try body(directory) } }
        if let error { throw error }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
    private func read<T>(track: AudioTrack, folder: ScopedFolder, _ body: (URL) throws -> T) throws -> T {
        let url = track.url(in: folder.url)
        let base = folder.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        var result: Result<T, Error>?, error: NSError?
        source.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { local in
            result = Result {
                try Task.checkCancellation()
                let expected = try FileFingerprint(local), value = try body(local)
                try Task.checkCancellation()
                guard try FileFingerprint(local) == expected else { throw MetadataIOError.changed }
                return value
            }
        }
        if let error { throw error }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
    private func copy(_ input: URL, to output: URL, progress: ExportProgress) throws {
        let reader = try FileHandle(forReadingFrom: input); defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        let size = try FileFingerprint(input).size
        var written: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let bytes = try reader.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try writer.write(contentsOf: bytes); written += UInt64(bytes.count)
            progress.update(size == 0 ? 0 : Double(written) / Double(size) * 0.95)
        }
        guard written == size else { throw MetadataIOError.changed }
        try writer.synchronize()
    }
    private func mp3(_ decoder: any PCMDecoding, to url: URL, progress: ExportProgress) throws {
        let channels = decoder.processingFormat.channelCount
        guard (1...2).contains(channels) else {
            throw MusicTextError.invalid("MP3 admite audio mono o estéreo. Exporta este archivo multicanal en Originales.")
        }
        let rate = decoder.processingFormat.sampleRate
        let sampleRate = [32000.0, 44100.0, 48000.0].contains(rate) ? rate : 44100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let encoder = lame_init() else { throw CocoaError(.fileWriteUnknown) }
        defer { lame_close(encoder) }
        guard lame_set_num_channels(encoder, Int32(channels)) == 0,
              lame_set_in_samplerate(encoder, Int32(sampleRate)) == 0,
              lame_set_out_samplerate(encoder, Int32(sampleRate)) == 0,
              lame_set_VBR(encoder, vbr_off) == 0,
              lame_set_brate(encoder, 320) == 0,
              lame_set_quality(encoder, 2) == 0,
              lame_set_bWriteVbrTag(encoder, 1) == 0,
              lame_init_params(encoder) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: url); defer { try? writer.close() }
        var bytes = [UInt8](repeating: 0, count: 16384 * 5 / 4 + 7200)
        func writeBytes(_ count: Int32) throws {
            guard count >= 0 else { throw CocoaError(.fileWriteUnknown) }
            try writer.write(contentsOf: Data(bytes.prefix(Int(count))))
        }
        // SFB 0.14 drops lame_encode_flush's returned bytes. Use the already
        // bundled LAME directly so the final frames and gapless header survive.
        try convert(decoder, to: format, progress: progress) { buffer in
            guard let samples = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            let count = lame_encode_buffer_ieee_float(encoder, samples[0], samples[channels == 1 ? 0 : 1], Int32(buffer.frameLength), &bytes, Int32(bytes.count))
            try writeBytes(count)
        }
        try Task.checkCancellation()
        let count = lame_encode_flush(encoder, &bytes, Int32(bytes.count))
        try writeBytes(count)
        let headerSize = lame_get_lametag_frame(encoder, nil, 0)
        guard headerSize > 0 else { throw CocoaError(.fileWriteUnknown) }
        var header = [UInt8](repeating: 0, count: Int(headerSize))
        guard lame_get_lametag_frame(encoder, &header, header.count) == headerSize else { throw CocoaError(.fileWriteUnknown) }
        try writer.seek(toOffset: 0); try writer.write(contentsOf: Data(header))
        try writer.synchronize()
    }
    private func wav(_ decoder: any PCMDecoding, to url: URL, progress: ExportProgress) throws {
        // AVAudioFile's settings cannot describe Float64 storage and silently
        // choose Float32. Write IEEE Float64 WAVE directly to retain all bits.
        let format = decoder.processingFormat, channels = Int(format.channelCount)
        guard (1...32).contains(channels), decoder.length > 0,
              format.sampleRate.isFinite, (1...384000).contains(format.sampleRate) else { throw CocoaError(.fileReadCorruptFile) }
        let order = try WaveChannelOrder(format)
        let layout = try IdentityPCMLayout(format)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { throw CocoaError(.fileReadCorruptFile) }
        guard format.sampleRate.rounded() == format.sampleRate else { throw MusicTextError.invalid("WAV no permite conservar esta frecuencia de muestreo.") }
        guard UInt64(decoder.length) <= (UInt64(UInt32.max) - 72) / UInt64(channels * 8) else {
            throw MusicTextError.invalid("La pista CUE supera el límite de 4 GB de WAV. Expórtala en MP3.")
        }
        let dataSize = UInt64(decoder.length) * UInt64(channels * 8)
        var header = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        append(UInt32(72 + dataSize)); header.append(Data("WAVEfmt ".utf8)); append(UInt32(40))
        append(UInt16(0xfffe)); append(UInt16(channels)); append(UInt32(format.sampleRate))
        append(UInt32(format.sampleRate) * UInt32(channels * 8)); append(UInt16(channels * 8)); append(UInt16(64))
        append(UInt16(22)); append(UInt16(64)); append(order.mask)
        header.append(contentsOf: [3,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113]) // IEEE float GUID
        header.append(Data("fact".utf8)); append(UInt32(4)); append(UInt32(decoder.length))
        header.append(Data("data".utf8)); append(UInt32(dataSize))
        try header.write(to: url, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: url); defer { try? writer.close() }
        try writer.seekToEnd()
        var samples = [UInt64](repeating: 0, count: 16384 * channels)
        var written: AVAudioFramePosition = 0
        while true {
            try Task.checkCancellation()
            try decoder.decode(into: input, length: input.frameCapacity)
            let count = Int(input.frameLength)
            if count == 0 { break }
            let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            guard buffers.count >= (layout.interleaved ? 1 : channels) else { throw CocoaError(.fileReadCorruptFile) }
            for (outputChannel, channel) in order.channels.enumerated() {
                let buffer = buffers[layout.interleaved ? 0 : channel]
                guard let data = buffer.mData, Int(buffer.mDataByteSize) >= count * layout.frameBytes else { throw CocoaError(.fileReadCorruptFile) }
                for frame in 0..<count {
                    let offset = frame * layout.frameBytes + (layout.interleaved ? channel * layout.sampleBytes : 0)
                    let value = layout.value(data, offset: offset)
                    guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    samples[frame * channels + outputChannel] = value.bitPattern.littleEndian
                }
            }
            try samples.withUnsafeBytes { try writer.write(contentsOf: Data($0.prefix(count * channels * 8))) }
            written += AVAudioFramePosition(count)
            progress.update(Double(written) / Double(decoder.length) * 0.95)
        }
        guard written == decoder.length else { throw CocoaError(.fileReadCorruptFile) }
        try writer.synchronize()
    }
    /// Bounded PCM conversion shared by both encoders; checks cancellation and
    /// rejects early EOF instead of publishing a silently truncated song.
    private func convert(_ decoder: any PCMDecoding, to format: AVAudioFormat, progress: ExportProgress,
                         write: (AVAudioPCMBuffer) throws -> Void) throws {
        guard decoder.length > 0,
              let converter = AVAudioConverter(from: decoder.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 16384),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { throw CocoaError(.fileWriteUnknown) }
        var written: AVAudioFramePosition = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: buffer, error: &conversionError) { requested, state in
                do {
                    try Task.checkCancellation()
                    try decoder.decode(into: input, length: min(requested, input.frameCapacity))
                    guard input.frameLength > 0 || decoder.position >= decoder.length else { throw CocoaError(.fileReadCorruptFile) }
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw CocoaError(.fileReadCorruptFile) }
            if buffer.frameLength > 0 { try write(buffer); written += AVAudioFramePosition(buffer.frameLength) }
            progress.update(Double(decoder.position) / Double(decoder.length) * 0.95)
            if status == .endOfStream { break }
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        let expected = Double(decoder.length) * format.sampleRate / decoder.processingFormat.sampleRate
        guard abs(Double(written) - expected) <= 1 else { throw CocoaError(.fileReadCorruptFile) }
    }
    private func metadata(at url: URL) throws -> AudioMetadata {
        if ["aac", "caf"].contains(url.pathExtension.lowercased()) { return AudioMetadata() }
        return try AudioFile(readingPropertiesAndMetadataFrom: url).metadata
    }
    private func apply(_ values: [MetadataField: String], to metadata: AudioMetadata) {
        metadata.title = values[.title]; metadata.artist = values[.artist]; metadata.albumTitle = values[.album]
        metadata.albumArtist = values[.albumArtist]; metadata.composer = values[.composer]; metadata.genre = values[.genre]
        metadata.releaseDate = values[.date]; metadata.comment = values[.comment]
        metadata.trackNumber = values[.trackNumber].flatMap(Int.init); metadata.trackTotal = values[.trackTotal].flatMap(Int.init)
        metadata.discNumber = values[.discNumber].flatMap(Int.init); metadata.discTotal = values[.discTotal].flatMap(Int.init)
    }
    private func save(_ metadata: AudioMetadata, to url: URL, preserving extras: [String: [String]], converted: Bool) throws {
        try Task.checkCancellation()
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.copyMetadata(from: metadata)
        file.metadata.removeAllAttachedPictures(); file.metadata.copyAttachedPicturesFrom(metadata)
        try file.writeMetadata()
        if ["mp3", "wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased()) {
            try ID3DateWriter.write(metadata.releaseDate ?? "", to: url)
            guard metadata.additionalMetadata == nil || metadata.additionalMetadata is [String: String] else {
                throw MusicTextError.invalid("No se pueden conservar las etiquetas adicionales de este archivo en MP3.")
            }
            var additional = (metadata.additionalMetadata as? [String: String] ?? [:]).mapValues { [$0] }.merging(extras) { _, source in source }
            if let mcn = metadata.mcn { additional["CATALOGNUMBER"] = [mcn] }
            if let sort = metadata.genreSortOrder { additional["GENRESORT"] = [sort] }
            if converted && !additional.isEmpty {
                try ID3ExportTags.write(additional, to: url)
                let saved = try ID3ExportTags.read(from: url)
                guard additional.allSatisfy({ saved[$0.key] == $0.value }) else {
                    throw MusicTextError.invalid("El MP3 no ha conservado las etiquetas adicionales. No se ha exportado la carpeta.")
                }
            }
        }
        let actual = try AudioFile(readingPropertiesAndMetadataFrom: url).metadata
        let values = MetadataService.values(actual)
        for (field, value) in MetadataService.values(metadata) where !value.isEmpty {
            guard values[field] == value else { throw MetadataIOError.verification(field) }
        }
        guard actual.attachedPictures.count == metadata.attachedPictures.count,
              metadata.attachedPictures.allSatisfy({ expected in
                  actual.attachedPictures.contains { $0.imageData == expected.imageData && $0.type == expected.type && ($0.description ?? "") == (expected.description ?? "") }
              }) else { throw MetadataIOError.invalidImage }
    }
    private func safeName(_ name: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let clean = name.components(separatedBy: unsafe).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // Reserve space for numbering, suffixes, extensions and provider limits.
        var result = ""
        for character in clean {
            if result.utf8.count + String(character).utf8.count > 160 { break }
            result.append(character)
        }
        return result.isEmpty ? "Playlist" : result
    }
}

/// Updated on the export worker; UI callbacks are throttled to ten per second.
private final class ExportProgress {
    let filename: String
    let index: Int
    let total: Int
    let callback: @Sendable (PlaylistFolderExport.Progress) -> Void
    private var last = Date.distantPast
    init(filename: String, index: Int, total: Int, callback: @escaping @Sendable (PlaylistFolderExport.Progress) -> Void) {
        self.filename = filename; self.index = index; self.total = total; self.callback = callback
    }
    func update(_ part: Double, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 0.1 else { return }
        last = now
        callback(.init(filename: filename, completed: index + (part >= 1 ? 1 : 0), total: total,
                       fraction: (Double(index) + max(0, min(1, part))) / Double(total)))
    }
}

/// WAVE extensible stores speakers in ascending mask-bit order. Retain their
/// meaning when a decoder presents the same speakers in another channel order.
struct WaveChannelOrder {
    let channels: [Int]
    let mask: UInt32
    init(_ format: AVAudioFormat) throws {
        let count = Int(format.channelCount)
        guard let layout = format.channelLayout else { channels = Array(0..<count); mask = count == 1 ? 4 : count == 2 ? 3 : 0; return }
        let value = layout.layout.pointee
        if count == 1 && value.mChannelLayoutTag == kAudioChannelLayoutTag_Mono { channels = [0]; mask = 4; return }
        var specifier = value.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap ? value.mChannelBitmap.rawValue : value.mChannelLayoutTag
        let property = value.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        var size: UInt32 = 0
        var labels: [AudioChannelLabel]
        func labelsAt(_ pointer: UnsafePointer<AudioChannelLayout>) throws -> [AudioChannelLabel] {
            guard pointer.pointee.mNumberChannelDescriptions == count,
                  let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { throw CocoaError(.fileReadCorruptFile) }
            let first = UnsafeRawPointer(pointer).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return UnsafeBufferPointer(start: first, count: count).map(\.mChannelLabel)
        }
        if value.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions { labels = try labelsAt(layout.layout) }
        else {
            guard AudioFormatGetPropertyInfo(property, 4, &specifier, &size) == noErr, size <= 4096 else { throw CocoaError(.fileReadUnsupportedScheme) }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { storage.deallocate() }
            guard AudioFormatGetProperty(property, 4, &specifier, &size, storage) == noErr else { throw CocoaError(.fileReadUnsupportedScheme) }
            labels = try labelsAt(UnsafePointer(storage.assumingMemoryBound(to: AudioChannelLayout.self)))
        }
        let speakers: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter,
            kAudioChannelLabel_CenterSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_TopCenterSurround,
            kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_VerticalHeightRight,
            kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight]
        let bits = labels.compactMap { speakers.firstIndex(of: $0) }
        guard bits.count == count, Set(bits).count == count else {
            throw MusicTextError.invalid("WAV no permite conservar esta distribución de canales.")
        }
        channels = bits.enumerated().sorted { $0.element < $1.element }.map(\.offset)
        mask = bits.reduce(0) { $0 | UInt32(1) << $1 }
    }
}
