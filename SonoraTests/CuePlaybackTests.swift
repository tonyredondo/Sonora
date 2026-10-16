import AVFAudio
import CryptoKit
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class CuePlaybackTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<132300 { buffer.floatChannelData![channel][frame] = Float(frame / 44100 + 1) / 10 } }
        try AVAudioFile(forWriting: root.appendingPathComponent("Live.wav"), settings: format.settings).write(from: buffer)
        try """
        PERFORMER "Sonora Live"
        TITLE "Concierto"
        FILE "Live.wav" WAVE
        TRACK 01 AUDIO
        TITLE "Entrada"
        INDEX 01 00:00:00
        TRACK 02 AUDIO
        TITLE "Centro"
        INDEX 01 00:01:00
        TRACK 03 AUDIO
        TITLE "Salida"
        INDEX 01 00:02:00
        """.write(to: root.appendingPathComponent("Live.cue"), atomically: true, encoding: .utf8)
        return root
    }
    func testRealDecodersRespectCueBoundariesSeekAndEndOfStream() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root), tracks = try FolderScanner.scan(root)
        for (index, track) in tracks.enumerated() {
            let prepared = try await MediaReader.prepare(track, folder: folder)
            let decoder = prepared.decoder
            defer { try? decoder.close() }
            XCTAssertEqual(decoder.length, 44100)
            XCTAssertEqual(prepared.details.duration, 1, accuracy: 0.00001)
            XCTAssertEqual(prepared.details.title, ["Entrada", "Centro", "Salida"][index])
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 80000)!
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            XCTAssertEqual(buffer.frameLength, 44100)
            XCTAssertEqual(buffer.floatChannelData![0][0], Float(index + 1) / 10, accuracy: 0.00001)
            try decoder.decode(into: buffer, length: 512); XCTAssertEqual(buffer.frameLength, 0)
            try decoder.seek(to: 22050); XCTAssertEqual(decoder.position, 22050)
            try decoder.decode(into: buffer, length: 512)
            XCTAssertEqual(buffer.floatChannelData![0][0], Float(index + 1) / 10, accuracy: 0.00001)
        }
    }
    func testCueLibraryRestoresDistinctTracksAndReadOnlyMetadata() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SonoraTests.Cue.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlaybackController(defaults: defaults); defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        XCTAssertEqual(player.queue.tracks.count, 3)
        player.play(index: 1)
        // Wait for the selected song to expose a duration before scrubbing it,
        // as the real player control requires.
        let deadline = Date().addingTimeInterval(4)
        while player.currentDetails?.title != "Centro" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.currentDetails?.title, "Centro")
        player.pause(); player.seek(to: 0.4)
        let track = try XCTUnwrap(player.current), snapshot = try await player.readMetadata(for: track)
        XCTAssertFalse(snapshot.canWrite)
        XCTAssertEqual(snapshot.values[.title], "Centro")
        let url = root.appendingPathComponent("Live.wav"), before = try Data(contentsOf: url)
        do { try await player.saveMetadata(for: track, expected: snapshot.fingerprint, patch: MetadataPatch(values: [.title: "Wrong shared tag"]))
            XCTFail("Virtual song must not overwrite the shared audio file's tags")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.map(\.id), player.queue.tracks.map(\.id))
        XCTAssertEqual(restored.current?.id, track.id)
        XCTAssertEqual(restored.currentTime, 0.4, accuracy: 0.02)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.library.state.songs.count, 3)
    }
    func testTimedLyricsAreRelativeToEachCueTrack() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try "[00:00.20]Entrada\n[00:01.20]Centro\n[00:02.20]Salida".write(to: root.appendingPathComponent("Live.lrc"), atomically: true, encoding: .utf8)
        let tracks = try FolderScanner.scan(root)
        let value = try await MediaReader.prepare(tracks[1], folder: ScopedFolder(root))
        XCTAssertEqual(value.details.lyrics.lines.map(\.text), ["Centro"])
        XCTAssertEqual(try XCTUnwrap(value.details.lyrics.lines.first?.time), 0.2, accuracy: 0.001)
    }
    func testVirtualIntervalsInFlacMp3AndAacDecodeTheExactFileFrameCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["flac", "mp3", "m4a"] {
            let directory = root.appendingPathComponent(ext)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Audio." + ext)
            try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: ext)), to: url)
            try "FILE \"Audio.\(ext)\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:10".write(to: directory.appendingPathComponent("Disc.cue"), atomically: true, encoding: .utf8)
            let original = try AudioDecoders.open(url), length = original.length
            try original.close()
            var decoded: Int64 = 0
            for track in try FolderScanner.scan(directory) {
                let prepared = try await MediaReader.prepare(track, folder: ScopedFolder(directory))
                let decoder = prepared.decoder
                let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
                repeat { try decoder.decode(into: buffer, length: 4096); decoded += Int64(buffer.frameLength) } while buffer.frameLength > 0
                try decoder.close()
            }
            XCTAssertEqual(decoded, length, ext)
        }
    }
    func testExistingImageQueuePlaylistAndFavoritesMigrateToCueSongsWithoutAutoplay() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = root.appendingPathComponent("Live.cue"), data = try Data(contentsOf: sheet)
        try FileManager.default.removeItem(at: sheet)
        let suite = "SonoraTests.CueMigration.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = PlaybackController(defaults: defaults); defer { old.stop() }
        await old.loadFolder(root, autoPlay: false)
        let deadline = Date().addingTimeInterval(4)
        while old.library.isIndexing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let id = try XCTUnwrap(old.current.flatMap { old.libraryID(for: $0) })
        let playlist = try XCTUnwrap(old.library.createPlaylist("Concierto guardado"))
        old.library.add([id], to: playlist); old.library.toggleFavorite(id); old.library.recordPlayed(id)
        old.seek(to: 1.4); old.stop()
        try data.write(to: sheet)
        let restored = PlaybackController(defaults: defaults); defer { restored.stop() }
        await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.count, 3)
        XCTAssertEqual(restored.currentDetails?.title, "Centro")
        XCTAssertEqual(restored.currentTime, 0.4, accuracy: 0.01)
        XCTAssertFalse(restored.isPlaying)
        let ids = restored.queue.tracks.compactMap { restored.libraryID(for: $0) }
        XCTAssertEqual(restored.library.state.playlists.first { $0.id == playlist }?.songIDs, ids)
        XCTAssertEqual(restored.library.state.favorites, Set(ids))
        XCTAssertTrue(restored.library.state.history.allSatisfy { restored.library.state.songs[$0.songID] != nil })
    }
    func testVolumeAnalysisMeasuresEachVirtualTrackAndCannotWriteSharedTags() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<132300 {
            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 1000 / 44100) * pow(2, Double(frame / 44100)) * 0.05)
        } }
        try AVAudioFile(forWriting: root.appendingPathComponent("Live.wav"), settings: format.settings).write(from: buffer)
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!)
        defer { player.stop() }
        await player.loadFolder(root, autoPlay: false)
        let targets = try player.volumeTargets(for: player.queue.tracks)
        let batch = try await VolumeAnalysisService.analyze(targets, album: true)
        XCTAssertEqual(batch.records.count, 3)
        let gains = try targets.map { try XCTUnwrap(batch.records[$0.id]?.gain) }
        XCTAssertEqual(gains[0] - gains[1], 6.02, accuracy: 0.1)
        XCTAssertEqual(gains[1] - gains[2], 6.02, accuracy: 0.1)
        try player.volumeAnalysis.record(batch)
        let before = try Data(contentsOf: root.appendingPathComponent("Live.wav"))
        let saved = await player.saveVolumeTags(targets) { _ in }
        XCTAssertEqual(saved.written, 0); XCTAssertEqual(saved.failures.count, 3)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Live.wav")), before)
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock(); private var values: [Float] = []
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            lock.lock(); defer { lock.unlock() }
            if values.count < 180000 { values.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) }
        }
        func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return values }
    }
    func testActualFolderControllerJoinsVirtualTracksWithoutInsertedOrRepeatedPCM() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = AudioPlayer(), capture = Capture()
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!, audioPlayer: audio)
        defer { player.stop() }
        audio.sourceNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
        defer { audio.sourceNode.removeTap(onBus: 0) }
        await player.loadFolder(root)
        try await Task.sleep(for: .milliseconds(3800))
        let samples = capture.snapshot(), start = try XCTUnwrap(samples.firstIndex { $0 > 0.09 })
        XCTAssertGreaterThanOrEqual(samples.count - start, 132300)
        guard samples.count - start >= 132300 else { return }
        for index in 0..<3 {
            let error = samples[(start + index * 44100)..<(start + (index + 1) * 44100)].map { abs($0 - Float(index + 1) / 10) }.max()!
            XCTAssertLessThan(error, 0.0001)
        }
        XCTAssertEqual(Set(player.library.state.history.map(\.songID)), Set(player.queue.tracks.compactMap { player.libraryID(for: $0) }))
    }
}
