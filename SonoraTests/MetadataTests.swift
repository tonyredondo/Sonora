import AVFAudio
import CryptoKit
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

final class MetadataTests: XCTestCase {
    func testAITranscriptionAttributionSurvivesTagSaveAndPlaybackReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        let lyrics = LyricsDocument.aiTranscriptionMarker + "\n[00:00.10]Una canción\n[00:00.20]Otra línea"
        // ID3, Vorbis comments and MP4 atoms must all retain the provenance header.
        for name in ["fixture.mp3", "fixture.flac", "fixture.m4a"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension))
            let url = root.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: url)
            let hash = try audioHash(url)
            let snapshot = try await MetadataService.read(url: url, folder: folder)
            _ = try await MetadataService.save(url: url, folder: folder, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.lyrics: lyrics]))
            let saved = try await MetadataService.read(url: url, folder: folder)
            XCTAssertEqual(saved.values[.lyrics], lyrics)
            let prepared = try await MediaReader.prepare(XCTUnwrap(AudioTrack(relativePath: name)), folder: folder)
            XCTAssertEqual(prepared.details.lyrics.attribution, "Transcrita por IA · ElevenLabs")
            XCTAssertEqual(prepared.details.lyricsSource, "Transcrita por IA · ElevenLabs")
            XCTAssertEqual(prepared.details.lyrics.lines.map(\.text), ["Una canción", "Otra línea"])
            try prepared.decoder.close()
            XCTAssertEqual(try audioHash(url), hash, "Lyrics must not alter audio: \(name)")
        }
    }

    @MainActor
    func testBatchSaveReportsConflictsAndPreservesPausedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        for name in ["a.flac", "b.flac"] { try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name)) }
        let suite = "SonoraTests.Batch.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false); player.seek(to: 0.1)
        let a = AudioTrack(relativePath: "a.flac")!, b = AudioTrack(relativePath: "b.flac")!
        let first = try await player.readMetadata(for: a), second = try await player.readMetadata(for: b)
        let external = try AudioFile(readingPropertiesAndMetadataFrom: root.appendingPathComponent("b.flac"))
        external.metadata.title = "Cambio externo"; try external.writeMetadata()
        let beforeA = try audioHash(root.appendingPathComponent("a.flac"))
        let result = await player.saveMetadataBatch([a, b], expected: [a.id: first.fingerprint, b.id: second.fingerprint], patch: MetadataPatch(values: [.album: "Disco editado"])) { _ in }
        XCTAssertEqual(result.written, 1); XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.01); XCTAssertFalse(player.isPlaying)
        let updated = try await player.readMetadata(for: a)
        XCTAssertEqual(updated.values[.album], "Disco editado")
        let untouched = try await player.readMetadata(for: b)
        XCTAssertEqual(untouched.values[.title], "Cambio externo"); XCTAssertEqual(untouched.values[.album], second.values[.album])
        XCTAssertEqual(try audioHash(root.appendingPathComponent("a.flac")), beforeA)
    }

    func testPlayerPrefersSynchronizedSidecarThenEmbeddedTimedLyrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("song.flac"), folder = try ScopedFolder(root)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: url)
        var document = try await MetadataService.read(url: url, folder: folder)
        document = try await MetadataService.save(url: url, folder: folder, expected: document.fingerprint, patch: MetadataPatch(values: [.lyrics: "Letra sencilla"]))
        try "[00:01]Primera\n[00:02]Segunda".write(to: root.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
        let track = AudioTrack(relativePath: "song.flac")!
        let first = try await MediaReader.prepare(track, folder: folder)
        XCTAssertTrue(first.details.lyrics.isTimed)
        XCTAssertEqual(first.details.lyrics.lines.count, 2)
        try? first.decoder.close()
        _ = try await MetadataService.save(url: url, folder: folder, expected: document.fingerprint, patch: MetadataPatch(values: [.lyrics: "[00:01]Incrustada"]))
        let next = try await MediaReader.prepare(track, folder: folder)
        XCTAssertEqual(next.details.lyrics.lines.first?.text, "Incrustada")
        XCTAssertEqual(next.details.tags[.lyrics], "[00:01]Incrustada")
        try? next.decoder.close()
    }

    private func audioHash(_ url: URL) throws -> String {
        let decoder = try NormalizedPCMDecoder(AudioDecoders.open(url)); defer { try? decoder.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
        var hash = SHA256()
        repeat {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            for channel in 0..<Int(buffer.format.channelCount) {
                hash.update(data: Data(bytes: buffer.floatChannelData![channel], count: Int(buffer.frameLength) * 4))
            }
        } while buffer.frameLength == buffer.frameCapacity
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testMetadataLyricsAndArtworkRoundTripPreservesAudioInInitialFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!.imageData
        for name in ["fixture.wav", "fixture.flac", "fixture.mp3", "fixture.m4a", "fixture.aiff", "fixture.alac.m4a"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension))
            let url = root.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: url)
            let beforeAudio = try audioHash(url)
            let before = try await MetadataService.read(url: url, folder: folder)
            let patch = MetadataPatch(values: [.title: "Luz 🌙", .artist: "Artista", .album: "Disco", .albumArtist: "Varios", .composer: "Compositora", .genre: "Rock", .date: "2026", .trackNumber: "2", .trackTotal: "12", .discNumber: "1", .discTotal: "2", .comment: "Comentario ñ", .lyrics: "[00:01.00]Una canción\n[00:02.00]Otra línea"], artwork: .replace(cover))
            let saved = try await MetadataService.save(url: url, folder: folder, expected: before.fingerprint, patch: patch)
            for (key, value) in patch.values { XCTAssertEqual(saved.values[key], value, "\(name): \(key)") }
            XCTAssertEqual(saved.artwork, cover, name)
            XCTAssertEqual(try audioHash(url), beforeAudio, "Audio changed: \(name)")
            let cleared = try await MetadataService.save(url: url, folder: folder, expected: saved.fingerprint, patch: MetadataPatch(values: [.lyrics: ""], artwork: .remove))
            XCTAssertEqual(cleared.values[.lyrics], ""); XCTAssertEqual(cleared.values[.title], "Luz 🌙")
            for (key, value) in patch.values where key != .lyrics { XCTAssertEqual(cleared.values[key], value, "Unedited field changed: \(name): \(key)") }
            XCTAssertNil(cleared.artwork)
            XCTAssertEqual(try audioHash(url), beforeAudio)
        }
    }

    func testConflictAndInvalidInputLeaveOriginalUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.flac"), folder = try ScopedFolder(root)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: url)
        let snapshot = try await MetadataService.read(url: url, folder: folder)
        var external = try Data(contentsOf: url); external.append(0)
        try external.write(to: url)
        do {
            _ = try await MetadataService.save(url: url, folder: folder, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.title: "Overwrite"]))
            XCTFail("Must reject an external change")
        } catch MetadataIOError.changed { }
        catch { XCTFail("Unexpected conflict error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), external)
        let latest = try await MetadataService.read(url: url, folder: folder)
        do {
            _ = try await MetadataService.save(url: url, folder: folder, expected: latest.fingerprint, patch: MetadataPatch(values: [.trackNumber: "-1"]))
            XCTFail("Must reject invalid track numbers")
        } catch { XCTAssertTrue(error is MetadataValidation) }
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["test.flac"])
    }
    @MainActor func testUserLyricSaveRejectsExternalLyricsShadowingWithoutChangingEitherFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac")), to: url)
        let sidecar = root.appendingPathComponent("song.lrc"), external = Data("[00:01]Original external lyric".utf8)
        try external.write(to: sidecar)
        let defaults = UserDefaults(suiteName: "SonoraTests.ShadowedLyrics.\(UUID())")!
        let player = PlaybackController(defaults: defaults); defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        let track = try XCTUnwrap(player.current), before = try Data(contentsOf: url)
        for lyrics in ["Replacement without times", ""] {
            let snapshot = try await player.readMetadata(for: track)
            do {
                try await player.saveMetadata(for: track, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.lyrics: lyrics]))
                XCTFail("A successful save must become the effective lyric")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("externa"))
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(try Data(contentsOf: sidecar), external)
        }
        let snapshot = try await player.readMetadata(for: track)
        let batch = await player.saveMetadataBatch([track], expected: [track.id: snapshot.fingerprint], patch: MetadataPatch(values: [.lyrics: ""]), progress: { _ in })
        XCTAssertEqual(batch.written, 0)
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try await player.saveMetadata(for: track, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.lyrics: "[00:01]New timed lyric"]))
        let saved = try await player.readMetadata(for: track)
        let effective = try await LyricsAudioPreparation.existingText(track: track, folder: player.folderAccess(for: track), embedded: saved.values[.lyrics] ?? "", expected: saved.fingerprint)
        XCTAssertEqual(effective, "[00:01]New timed lyric")
    }

}
