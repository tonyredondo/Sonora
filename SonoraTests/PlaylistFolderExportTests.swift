import AVFAudio
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class PlaylistFolderExportTests: XCTestCase {
    private var root: URL!
    private var library: MusicLibrary!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("destination"), withIntermediateDirectories: true)
        suite = "SonoraTests.FolderExport.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        library = MusicLibrary(defaults: defaults)
    }
    override func tearDown() async throws {
        library.cancelIndexing()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private var source: URL { root.appendingPathComponent("source") }
    private var destination: URL { root.appendingPathComponent("destination") }
    @discardableResult private func copy(_ fixture: String, as name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: (fixture as NSString).deletingPathExtension, withExtension: (fixture as NSString).pathExtension)), to: url)
        return url
    }
    private func playlist(_ paths: [String]) throws -> String {
        let tracks = try FolderScanner.scan(source)
        let sourceID = try library.register(ScopedFolder(source), tracks: tracks)
        library.cancelIndexing()
        let id = try XCTUnwrap(library.createPlaylist("Viaje"))
        library.add(try paths.map { path in try XCTUnwrap(tracks.first { $0.relativePath == path }).withSource(sourceID).id }, to: id)
        return id
    }
    private func entries(_ folder: URL) throws -> [M3UEntry] {
        let list = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "m3u8" })
        return try M3UPlaylist.decode(Data(contentsOf: list), utf8Only: true).entries
    }
    func testOriginalFolderIsPortableOrderedAndDoesNotOverwriteAnything() async throws {
        let first = try copy("fixture.flac", as: "B.flac"), second = try copy("fixture.mp3", as: "A.mp3")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let id = try playlist(["B.flac", "A.mp3"])
        let existing = destination.appendingPathComponent("Viaje")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("mine.txt"))
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Viaje", format: .original)
        XCTAssertNotEqual(folder, existing)
        let list = try entries(folder)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].path.hasPrefix("01 - ")); XCTAssertTrue(list[1].path.hasPrefix("02 - "))
        XCTAssertEqual(list.map { ($0.path as NSString).pathExtension }, ["flac", "mp3"])
        XCTAssertTrue(list.allSatisfy { !$0.path.contains("/") && $0.start == nil && $0.end == nil })
        for (index, entry) in list.enumerated() { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(entry.path)), originals[index]) }
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("mine.txt")), Data("keep".utf8))
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        for entry in try entries(moved) {
            let decoder = try AudioDecoders.open(moved.appendingPathComponent(entry.path)); try decoder.close()
        }
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }
    func testWAVToMP3PreservesTagsPicturesSidecarLyricsAndSource() async throws {
        let input = try copy("fixture.wav", as: "song.wav")
        let artFile = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac")))
        let cover = try XCTUnwrap(artFile.metadata.attachedPictures.first?.imageData)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: input)
        file.metadata.title = "Luz 🌙"; file.metadata.artist = "Autor"; file.metadata.albumTitle = "Álbum"
        file.metadata.albumArtist = "Varios"; file.metadata.composer = "Compositora"; file.metadata.genre = "Rock"
        file.metadata.releaseDate = "2026"; file.metadata.trackNumber = 3; file.metadata.trackTotal = 12
        file.metadata.discNumber = 1; file.metadata.discTotal = 2; file.metadata.comment = "Comentario ñ"
        file.metadata.isrc = "ESABC2600001"; file.metadata.bpm = 123
        file.metadata.replayGainTrackGain = -4.25; file.metadata.replayGainTrackPeak = 0.85
        file.metadata.attachPicture(AttachedPicture(imageData: cover, type: .frontCover))
        try file.writeMetadata(); try ID3DateWriter.write("2026", to: input)
        let lyric = LyricsDocument.aiRepairMarker + "\n[00:00.10]Primera\n[00:00.20]Segunda"
        try lyric.write(to: source.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: input), id = try playlist(["song.wav"])
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Viaje", format: .mp3)
        let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
        XCTAssertEqual(output.pathExtension, "mp3")
        let saved = try AudioFile(readingPropertiesAndMetadataFrom: output)
        for (field, value) in MetadataService.values(file.metadata) where field != .lyrics { XCTAssertEqual(MetadataService.values(saved.metadata)[field], value, "\(field)") }
        XCTAssertEqual(saved.metadata.lyrics, lyric)
        XCTAssertEqual(saved.metadata.attachedPictures.first?.imageData, cover)
        XCTAssertEqual(saved.metadata.isrc, "ESABC2600001"); XCTAssertEqual(saved.metadata.bpm, 123)
        XCTAssertEqual(saved.metadata.replayGainTrackGain ?? 0, -4.25, accuracy: 0.006)
        XCTAssertEqual(saved.metadata.replayGainTrackPeak ?? 0, 0.85, accuracy: 0.000001)
        let attachment = XCTAttachment(data: try Data(contentsOf: output), uniformTypeIdentifier: "public.mp3")
        attachment.name = "metadata-roundtrip-320"; attachment.lifetime = .keepAlways; add(attachment)
        try assertCBR320(output)
        let decoder = try AudioDecoders.open(output); defer { try? decoder.close() }
        let original = try AudioDecoders.open(input); defer { try? original.close() }
        XCTAssertEqual(Double(decoder.length) / decoder.processingFormat.sampleRate, Double(original.length) / original.processingFormat.sampleRate, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }
    func testExistingMP3IsNotRecompressed() async throws {
        let input = try copy("fixture.mp3", as: "song.mp3"), before = try Data(contentsOf: input)
        let folder = try await PlaylistFolderExport.exportPlaylist(playlist(["song.mp3"]), library: library, folder: destination, name: "Viaje", format: .mp3)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(XCTUnwrap(entries(folder).first?.path))), before)
    }
    func testMP3ExportPreservesAdditionalTagsAndMultiplePictures() async throws {
        let input = try copy("fixture-cover.flac", as: "song.flac")
        let file = try AudioFile(readingPropertiesAndMetadataFrom: input)
        let front = try XCTUnwrap(file.metadata.attachedPictures.first?.imageData)
        let back = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "AppIcon60x60@2x", withExtension: "png")))
        file.metadata.removeAllAttachedPictures()
        file.metadata.attachPicture(AttachedPicture(imageData: front, type: .frontCover, description: "Front"))
        file.metadata.attachPicture(AttachedPicture(imageData: back, type: .backCover, description: "Back"))
        file.metadata.additionalMetadata = ["LABEL": "Sello ñ", "CUSTOM_SONORA": "two\nlines"]
        file.metadata.mcn = "1234567890123"
        try file.writeMetadata()
        let native = try AudioFile(readingPropertiesAndMetadataFrom: input).metadata
        XCTAssertEqual((native.additionalMetadata as? [String: String])?["CUSTOM_SONORA"], "two\nlines")
        let id = try playlist(["song.flac"])
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Metadata", format: .mp3)
        let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
        let saved = try AudioFile(readingPropertiesAndMetadataFrom: output).metadata
        XCTAssertEqual(saved.attachedPictures.count, 2)
        for expected in native.attachedPictures {
            XCTAssertTrue(saved.attachedPictures.contains { $0.type == expected.type && $0.imageData == expected.imageData && ($0.description ?? "") == (expected.description ?? "") })
        }
        let extra = try ID3ExportTags.read(from: output)
        XCTAssertEqual(extra["LABEL"], ["Sello ñ"]); XCTAssertEqual(extra["CUSTOM_SONORA"], ["two\nlines"])
        XCTAssertEqual(extra["CATALOGNUMBER"], ["1234567890123"])
        try assertCBR320(output)
    }
    func testExistingMP3WithExternalLyricsRetainsItsEncodedAudioAndPictures() async throws {
        let input = try copy("fixture.mp3", as: "song.mp3")
        let file = try AudioFile(readingPropertiesAndMetadataFrom: input)
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!
        file.metadata.attachPicture(cover); try file.writeMetadata()
        let extras = ["CUSTOM_SONORA": ["first", "", "second"]]
        try ID3ExportTags.write(extras, to: input)
        // TagLib normalizes empty TXXX values when it parses the fixture.
        // Compare against the actual source, including both meaningful values.
        let sourceExtras = try ID3ExportTags.read(from: input)
        XCTAssertEqual(sourceExtras["CUSTOM_SONORA"], ["first", "second"])
        let before = try Data(contentsOf: input)
        try "[00:00.1]External".write(to: source.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
        let id = try playlist(["song.mp3"])
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Passthrough", format: .mp3)
        let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path)), after = try Data(contentsOf: output)
        func payload(_ data: Data) -> Data {
            let start = data.starts(with: Data("ID3".utf8)) ? 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) } : 0
            let end = data.count >= 128 && data.suffix(128).starts(with: Data("TAG".utf8)) ? data.count - 128 : data.count
            return data.subdata(in: start..<end)
        }
        XCTAssertEqual(payload(before), payload(after))
        XCTAssertEqual(try Data(contentsOf: input), before)
        let saved = try AudioFile(readingPropertiesAndMetadataFrom: output).metadata
        XCTAssertEqual(saved.attachedPictures.count, 1); XCTAssertEqual(saved.attachedPictures.first?.imageData, cover.imageData)
        XCTAssertEqual(saved.lyrics, "[00:00.1]External")
        XCTAssertEqual(try ID3ExportTags.read(from: output)["CUSTOM_SONORA"], sourceExtras["CUSTOM_SONORA"])
    }
    private func writePCM(_ name: String, rate: Double, channels: AVAudioChannelCount) throws -> URL {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A : channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) { for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / rate) * 0.25 * Double(channel + 1) / Double(channels))
        } }
        let url = source.appendingPathComponent(name)
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
    func testMP3ResamplesLowAndHighRatesAndPreservesMonoOrStereoDuration() async throws {
        for (rate, channels) in [(22050.0, AVAudioChannelCount(1)), (96000.0, AVAudioChannelCount(2))] {
            let name = "\(Int(rate)).wav"
            try writePCM(name, rate: rate, channels: channels)
            let id = try playlist([name])
            let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: name, format: .mp3)
            let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
            let decoder = try AudioDecoders.open(output); defer { try? decoder.close() }
            XCTAssertEqual(decoder.processingFormat.sampleRate, 44100)
            XCTAssertEqual(decoder.processingFormat.channelCount, channels)
            XCTAssertEqual(Double(decoder.length) / 44100, 1, accuracy: 0.001)
            try assertCBR320(output)
        }
    }
    func testMultichannelMP3FailsExplicitlyWithoutPublishingOrChangingSource() async throws {
        let input = try writePCM("surround.wav", rate: 48000, channels: 6), before = try Data(contentsOf: input)
        let id = try playlist(["surround.wav"])
        do {
            _ = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Surround", format: .mp3)
            XCTFail("Must not silently downmix")
        } catch { XCTAssertTrue(error.localizedDescription.contains("multicanal")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: input), before)
    }
    func testMultichannelCueOriginalPreservesSpeakersAndSamples() async throws {
        let input = try writePCM("surround.wav", rate: 48000, channels: 6)
        try "FILE \"surround.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:30\n".write(to: source.appendingPathComponent("surround.cue"), atomically: true, encoding: .utf8)
        let tracks = try FolderScanner.scan(source), sourceID = try library.register(ScopedFolder(source), tracks: tracks)
        library.cancelIndexing()
        let id = try XCTUnwrap(library.createPlaylist("Surround CUE"))
        library.add([try XCTUnwrap(tracks.first { $0.cue?.number == 1 }).withSource(sourceID).id], to: id)
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Surround CUE", format: .original)
        let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
        let original = try AudioDecoders.openForIdentity(input), exported = try AudioDecoders.openForIdentity(output)
        defer { try? original.close(); try? exported.close() }
        let layout = try XCTUnwrap(original.processingFormat.channelLayout)
        let sourceLayout = layout.layout.pointee
        XCTAssertEqual(sourceLayout.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelDescriptions)
        let pointer = UnsafeRawPointer(layout.layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
        let labels = UnsafeBufferPointer(start: pointer, count: Int(sourceLayout.mNumberChannelDescriptions)).map(\.mChannelLabel)
        // Core Audio's WAV fixture exposes side surrounds, not rear surrounds.
        // Verify that independent input contract before inspecting the WAVE mask.
        XCTAssertEqual(labels, [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect])
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self)) }, 0x60f)
        XCTAssertEqual(exported.length, 19200); XCTAssertEqual(exported.processingFormat.channelCount, 6)
        let first = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 128)!, second = AVAudioPCMBuffer(pcmFormat: exported.processingFormat, frameCapacity: 128)!
        try original.decode(into: first, length: 128); try exported.decode(into: second, length: 128)
        let a = try IdentityPCMLayout(first.format), b = try IdentityPCMLayout(second.format)
        let ab = UnsafeMutableAudioBufferListPointer(first.mutableAudioBufferList), bb = UnsafeMutableAudioBufferListPointer(second.mutableAudioBufferList)
        for channel in 0..<6 { for frame in 0..<128 {
            let expected = a.value(ab[a.interleaved ? 0 : channel].mData!, offset: frame * a.frameBytes + (a.interleaved ? channel * a.sampleBytes : 0))
            let actual = b.value(bb[b.interleaved ? 0 : channel].mData!, offset: frame * b.frameBytes + (b.interleaved ? channel * b.sampleBytes : 0))
            XCTAssertEqual(actual, expected, accuracy: 1e-15)
        } }
    }
    func testExplicitMonoSpeakerRemainsLFE() throws {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 8)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: AVAudioChannelLayout(layout: &layout))
        let order = try WaveChannelOrder(format)
        XCTAssertEqual(order.mask, 8); XCTAssertEqual(order.channels, [0])
    }
    func testMP3ConversionOfSupportedFixtureFormatsPreservesDurationAndSource() async throws {
        for fixture in ["fixture.flac", "fixture.aiff", "fixture.m4a", "fixture.alac.m4a", "extra.ogg", "extra.opus", "extra.wv", "extra.tta", "extra.aac", "extra.caf"] {
            let input = try copy(fixture, as: fixture), before = try Data(contentsOf: input)
            let id = try playlist([fixture])
            let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: fixture, format: .mp3)
            let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
            let original = try AudioDecoders.openForIdentity(input), actual = try AudioDecoders.open(output)
            defer { try? original.close(); try? actual.close() }
            XCTAssertEqual(Double(actual.length) / actual.processingFormat.sampleRate, Double(original.length) / original.processingFormat.sampleRate, accuracy: 0.001, fixture)
            try assertCBR320(output)
            XCTAssertEqual(try Data(contentsOf: input), before)
        }
    }
    func testOriginalRawAudioRetainsExternalArtworkAndLyricsOnReopen() async throws {
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!.imageData
        try cover.write(to: source.appendingPathComponent("cover.jpg"))
        for ext in ["aac", "caf"] {
            let input = try copy("extra.\(ext)", as: "song.\(ext)"), before = try Data(contentsOf: input)
            try "Lyrics".write(to: source.appendingPathComponent("song.txt"), atomically: true, encoding: .utf8)
            let id = try playlist(["song.\(ext)"])
            let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: ext, format: .original)
            let name = try XCTUnwrap(entries(folder).first?.path), output = folder.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: output), before)
            XCTAssertEqual(LocalArtwork.data(for: output), cover)
            let prepared = try await MediaReader.prepare(XCTUnwrap(AudioTrack(relativePath: name)), folder: ScopedFolder(folder))
            defer { try? prepared.decoder.close() }
            XCTAssertNotNil(prepared.details.artwork); XCTAssertEqual(prepared.details.lyrics.lines.map(\.text), ["Lyrics"])
        }
    }
    func testCueOriginalKeepsAll32BitSamplesOfTheSelectedInterval() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 44100, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.int32ChannelData![0][frame] = Int32((frame * 65537) % Int(Int32.max)) }
        try AVAudioFile(forWriting: source.appendingPathComponent("disk.wav"), settings: format.settings, commonFormat: .pcmFormatInt32, interleaved: false).write(from: buffer)
        try "FILE \"disk.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00\nTRACK 03 AUDIO\nINDEX 01 00:02:00\n".write(to: source.appendingPathComponent("disk.cue"), atomically: true, encoding: .utf8)
        let tracks = try FolderScanner.scan(source), sourceID = try library.register(ScopedFolder(source), tracks: tracks)
        library.cancelIndexing()
        let id = try XCTUnwrap(library.createPlaylist("Precision"))
        library.add([try XCTUnwrap(tracks.first { $0.cue?.number == 2 }).withSource(sourceID).id], to: id)
        let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Precision", format: .original)
        let output = folder.appendingPathComponent(try XCTUnwrap(entries(folder).first?.path))
        let file = try AudioDecoders.openForIdentity(output); defer { try? file.close() }
        XCTAssertEqual(file.length, 44100)
        XCTAssertEqual(file.processingFormat.streamDescription.pointee.mBitsPerChannel, 64)
        let actual = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100))
        try file.decode(into: actual, length: 44100)
        let samples = try IdentityPCMLayout(actual.format), data = actual.audioBufferList.pointee.mBuffers.mData!
        for frame in 0..<44100 {
            let expected = Double(buffer.int32ChannelData![0][frame + 44100]) / 2147483648
            let value = samples.value(data, offset: frame * samples.frameBytes)
            guard abs(value - expected) <= 1e-15 else {
                XCTFail("Sample \(frame) changed: \(value) != \(expected)"); return
            }
        }
    }
    /// TagLib's average estimate includes the LAME header on very short clips.
    /// Inspect the actual MPEG frame headers to prove constant 320 kb/s audio.
    private func assertCBR320(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var cursor = 0, frames = 0
        if data.starts(with: Data("ID3".utf8)) {
            cursor = 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
        }
        while cursor + 4 <= data.count {
            if data[cursor...].starts(with: Data("TAG".utf8)) { break }
            let header = Array(data[cursor..<cursor + 4])
            XCTAssertEqual(header[0], 0xff); XCTAssertEqual(header[1] & 0xfe, 0xfa)
            XCTAssertEqual(header[2] >> 4, 14, "Every MPEG1 layer III frame must use the 320 kb/s bitrate index")
            let rateIndex = Int((header[2] >> 2) & 3)
            guard rateIndex < 3 else { XCTFail("Invalid sample rate"); return }
            cursor += 144_000 * 320 / [44100, 48000, 32000][rateIndex] + Int((header[2] >> 1) & 1)
            frames += 1
        }
        XCTAssertGreaterThan(frames, 1)
        XCTAssertLessThanOrEqual(cursor, data.count, "MPEG end \(cursor), file bytes \(data.count)")
        if cursor <= data.count { XCTAssertTrue(cursor == data.count || data[cursor...].starts(with: Data("TAG".utf8))) }
    }
    func testFailureAfterFirstSongLeavesNoPartialExport() async throws {
        try copy("fixture.flac", as: "good.flac"); try copy("fixture.flac", as: "missing.flac")
        let id = try playlist(["good.flac", "missing.flac"])
        try FileManager.default.removeItem(at: source.appendingPathComponent("missing.flac"))
        do { _ = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Viaje", format: .original); XCTFail("Missing audio must fail explicitly") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
    func testCancellationDuringExportRemovesStagingAndPreservesSources() async throws {
        let input = try copy("fixture.wav", as: "song.wav"), before = try Data(contentsOf: input)
        let id = try playlist(["song.wav"])
        do {
            _ = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "Viaje", format: .mp3) { value in
                if value.fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: input), before)
    }
    func testCueExportsOnlySelectedAudioAndAdjustsLyrics() async throws {
        try copy("fixture.flac", as: "disk.flac")
        try "FILE \"disk.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"Inicio\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Final\"\nINDEX 01 00:00:10\n".write(to: source.appendingPathComponent("disk.cue"), atomically: true, encoding: .utf8)
        try "[00:00.01]First\n[00:00.15]Second".write(to: source.appendingPathComponent("disk.lrc"), atomically: true, encoding: .utf8)
        let tracks = try FolderScanner.scan(source), sourceID = try library.register(ScopedFolder(source), tracks: tracks)
        library.cancelIndexing()
        let track = try XCTUnwrap(tracks.first { $0.cue?.number == 2 })
        let id = try XCTUnwrap(library.createPlaylist("CUE")); library.add([track.withSource(sourceID).id], to: id)
        for format in PlaylistFolderExport.Format.allCases {
            let folder = try await PlaylistFolderExport.exportPlaylist(id, library: library, folder: destination, name: "CUE", format: format)
            let entry = try XCTUnwrap(entries(folder).first), output = folder.appendingPathComponent(entry.path)
            XCTAssertEqual(output.pathExtension, format == .original ? "wav" : "mp3")
            let expected = try AudioDecoders.open(track.url(in: source), cue: track.cue), actual = try AudioDecoders.open(output)
            defer { try? expected.close(); try? actual.close() }
            XCTAssertEqual(Double(actual.length) / actual.processingFormat.sampleRate, Double(expected.length) / expected.processingFormat.sampleRate, accuracy: 0.04)
            let metadata = try AudioFile(readingPropertiesAndMetadataFrom: output).metadata
            XCTAssertEqual(metadata.title, "Final")
            let lyrics = LyricsDocument(text: metadata.lyrics ?? "")
            XCTAssertEqual(lyrics.lines.map(\.text), ["Second"])
            XCTAssertEqual(try XCTUnwrap(lyrics.lines.first?.time), 0.15 - 10.0 / 75, accuracy: 0.002)
        }
    }
}
