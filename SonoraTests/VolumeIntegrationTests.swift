import AVFAudio
import CryptoKit
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class VolumeIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func copy(_ name: String, to root: URL) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension))
        let url = root.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: url); return url
    }
    private func pcmHash(_ url: URL) throws -> SHA256.Digest {
        let decoder = try NormalizedPCMDecoder(AudioDecoders.open(url)); defer { try? decoder.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 997)!
        var hash = SHA256()
        repeat {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            for channel in 0..<Int(buffer.format.channelCount) { hash.update(data: Data(bytes: buffer.floatChannelData![channel], count: Int(buffer.frameLength) * 4)) }
        } while buffer.frameLength == buffer.frameCapacity
        return hash.finalize()
    }
    func testMeasuredTagsRoundTripInNineFormatsPreservesAudioAndOtherMetadata() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!.imageData
        for name in ["volume.wav", "volume.flac", "volume.mp3", "volume.m4a", "volume.alac.m4a", "volume.aiff", "extra.ogg", "extra.opus", "extra.wv"] {
            let url = try copy(name, to: root), original = try await MetadataService.read(url: url, folder: folder)
            let tagged = try await MetadataService.save(url: url, folder: folder, expected: original.fingerprint,
                patch: MetadataPatch(values: [.date: "2026", .lyrics: "[00:01]Conservar letra", .comment: "Conservar comentario"], artwork: .replace(cover)))
            let audio = try pcmHash(url)
            let measured = try await VolumeAnalysisService.analyze([.init(id: name, url: url, folder: folder)], album: true)
            let track = try XCTUnwrap(measured.records[name]), album = try XCTUnwrap(measured.album)
            let gain = ReplayGain(trackGain: track.gain, trackPeak: track.peak, albumGain: album.gain, albumPeak: album.peak)
            let saved = try await MetadataService.save(url: url, folder: folder, expected: tagged.fingerprint, patch: MetadataPatch(), replayGain: gain)
            XCTAssertEqual(try XCTUnwrap(saved.replayGain.trackGain), track.gain, accuracy: 0.006, name)
            XCTAssertEqual(try XCTUnwrap(saved.replayGain.trackPeak), track.peak, accuracy: 0.000001, name)
            XCTAssertEqual(try XCTUnwrap(saved.replayGain.albumGain), album.gain, accuracy: 0.006, name)
            XCTAssertEqual(try XCTUnwrap(saved.replayGain.albumPeak), album.peak, accuracy: 0.000001, name)
            XCTAssertEqual(saved.values, tagged.values, name); XCTAssertEqual(saved.artwork, cover, name)
            XCTAssertEqual(try pcmHash(url), audio, name)
        }
    }
    func testConflictAndReadOnlyFormatDoNotRewriteTheOriginal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root), url = try copy("volume.flac", to: root)
        let before = try await MetadataService.read(url: url, folder: folder)
        _ = try await MetadataService.save(url: url, folder: folder, expected: before.fingerprint, patch: MetadataPatch(values: [.title: "Cambio externo"]))
        let external = try Data(contentsOf: url), gain = ReplayGain(trackGain: -6, trackPeak: 0.5)
        do {
            _ = try await MetadataService.save(url: url, folder: folder, expected: before.fingerprint, patch: MetadataPatch(), replayGain: gain)
            XCTFail("Stale measurements must not overwrite an external edit")
        } catch MetadataIOError.changed { }
        XCTAssertEqual(try Data(contentsOf: url), external)
        let caf = try copy("extra.caf", to: root), cafData = try Data(contentsOf: caf)
        do {
            _ = try await MetadataService.save(url: caf, folder: folder, expected: FileFingerprint(caf), patch: MetadataPatch(), replayGain: gain)
            XCTFail("CAF metadata must remain read-only")
        } catch MetadataIOError.unsupported { }
        XCTAssertEqual(try Data(contentsOf: caf), cafData)
    }

    private final class Capture: @unchecked Sendable {
        let lock = NSLock(); private var samples: [Float] = []
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?.pointee else { return }
            lock.lock(); defer { lock.unlock() }
            let count = min(Int(buffer.frameLength), 96000 - samples.count)
            if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
        }
        func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    func testLocalAnalysisAffectsRealPlaybackWithoutWritingTagsAndRestoresPaused() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try copy("volume.wav", to: root), before = try Data(contentsOf: url)
        let suite = "SonoraTests.VolumePlayback.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = AudioPlayer(), player = PlaybackController(defaults: defaults, audioPlayer: audio)
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        let targets = try player.volumeTargets(for: player.queue.tracks)
        try player.volumeAnalysis.record(try await VolumeAnalysisService.analyze(targets, album: false))
        player.setListening(normalization: .track)
        let deadline = Date().addingTimeInterval(5)
        while player.isPreparing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(player.isPlaying)
        let capture = Capture()
        audio.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { audio.mainMixerNode.removeTap(onBus: 0) }
        player.resume()
        while capture.snapshot().count < 25000 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let samples = capture.snapshot(), first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.001 }) + 2000
        let last = min(first + 12000, samples.count)
        XCTAssertGreaterThan(last - first, 5000)
        let rms = sqrt(samples[first..<last].reduce(0.0) { $0 + Double($1 * $1) } / Double(last - first))
        XCTAssertEqual(rms, 0.089, accuracy: 0.003, "-18 LUFS stereo tone after local ReplayGain")
        XCTAssertEqual(try Data(contentsOf: url), before, "Analysis must not write tags automatically")
        player.pause(); player.save()
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertFalse(restored.isPlaying)
        XCTAssertGreaterThan(restored.currentDetails?.normalizationGain ?? 0, 1.3)
        XCTAssertEqual(restored.volumeAnalysis.records, player.volumeAnalysis.records)
    }

    func testBatchTagSaveReportsConflictAndKeepsOtherAlbumMeasurementsFresh() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.wav", "b.wav"] {
            let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "volume", withExtension: "wav"))
            try FileManager.default.copyItem(at: original, to: root.appendingPathComponent(name))
        }
        let suite = "SonoraTests.VolumeBatch.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false); player.seek(to: 0.1)
        let targets = try player.volumeTargets(for: player.queue.tracks)
        try player.volumeAnalysis.record(try await VolumeAnalysisService.analyze(targets, album: true))
        let second = targets[1], file = try AudioFile(readingPropertiesAndMetadataFrom: second.url)
        file.metadata.title = "Edición externa"; try file.writeMetadata()
        let external = try Data(contentsOf: second.url)
        let result = await player.saveVolumeTags(targets) { _ in }
        XCTAssertEqual(result.written, 1); XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: second.url), external)
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.02); XCTAssertFalse(player.isPlaying)
        let candidate = try XCTUnwrap(player.volumeAnalysis.candidate(for: targets[0].id, members: targets))
        XCTAssertNotNil(candidate.validated(fingerprint: try FileFingerprint(targets[0].url))?.trackGain)
        XCTAssertNil(candidate.validated(fingerprint: try FileFingerprint(targets[0].url))?.albumGain)
    }
}
