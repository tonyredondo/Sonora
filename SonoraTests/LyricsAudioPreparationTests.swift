import AVFAudio
import CryptoKit
import SonoraCore
import XCTest
@testable import Sonora

private actor DecodedDurationCatalog: MetadataLookupTransport {
    let duration: Double
    init(duration: Double) { self.duration = duration }
    func send(_ request: URLRequest) throws -> MetadataHTTPResponse {
        XCTAssertEqual(request.url?.path, "/v1/lyrics", "A matching catalog result must not use a paid route")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "duration" }?.value, String(Int(duration.rounded())))
        let value: [String: Any] = ["id": 1, "trackName": "Song", "artistName": "Artist", "albumName": "Album", "duration": duration,
                                  "instrumental": false, "plainLyrics": "Hello\nAgain", "syncedLyrics": "[00:00.10]Hello\n[00:03.90]Again"]
        return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["sources": [], "data": value]), status: 200, contentType: "application/json")
    }
}

final class LyricsAudioPreparationTests: XCTestCase {
    private func fixture(frames: AVAudioFrameCount = 88200) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.2 * sin(Float(frame) * 0.03) } }
        try AVAudioFile(forWriting: root.appendingPathComponent("sample.wav"), settings: format.settings).write(from: buffer)
        return root
    }
    func testExportsCanonicalMonoPCMWithoutChangingOriginalAndFindsSidecar() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav"), original = try Data(contentsOf: url)
        try "Known lyrics\nSecond line".write(to: root.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let track = try XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder = try ScopedFolder(root), fingerprint = try FileFingerprint(url)
        let audio = try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: fingerprint)
        XCTAssertEqual(audio.count, 64044); XCTAssertEqual(String(decoding: audio.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(Array(audio[16..<36]), [16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0])
        XCTAssertTrue(audio[44...].contains { $0 != 0 })
        let text = try await LyricsAudioPreparation.existingText(track: track, folder: folder, embedded: "", expected: fingerprint)
        XCTAssertEqual(text, "Known lyrics\nSecond line")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["sample.txt", "sample.wav"])
    }
    func testChangedFileAndCancelledPreparationNeverReturnAudio() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.wav"), fingerprint = try FileFingerprint(url)
        let track = try XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder = try ScopedFolder(root)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)], ofItemAtPath: url.path)
        do { _ = try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: fingerprint); XCTFail("Changed audio must not be uploaded") }
        catch { XCTAssertEqual(error.localizedDescription, MetadataIOError.changed.localizedDescription) }
        let operation = Task { try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: FileFingerprint(url)) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Must cancel") } catch is CancellationError { }
    }
    func testFractionalDurationsKeepResampledAudioAndHeaderConsistent() async throws {
        for count: AVAudioFrameCount in [44101, 88202, 105841] {
            let root = try fixture(frames: count); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("sample.wav")
            let audio = try await LyricsAudioPreparation.prepare(track: XCTUnwrap(AudioTrack(relativePath: "sample.wav")), folder: ScopedFolder(root), expected: FileFingerprint(url))
            let frames = Double(audio.count - 44) / 2
            XCTAssertEqual(frames / 16000, Double(count) / 44100, accuracy: 1 / 16000)
            let length = Array(audio[40..<44]).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            XCTAssertEqual(length, audio.count - 44)
        }
    }

    @MainActor func testLyricsSheetLoadsOnlyTheSelectedCueSegment() async throws {
        let root = try fixture(frames: 882000); defer { try? FileManager.default.removeItem(at: root) }
        try "[00:02]Earlier track\n[00:12]Selected phrase\n[00:17]Following track".write(to: root.appendingPathComponent("sample.lrc"), atomically: true, encoding: .utf8)
        let cue = "FILE \"sample.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:10:00\nTRACK 03 AUDIO\nINDEX 01 00:15:00"
        let track = try CueSheet.tracks(data: Data(cue.utf8), sheetPath: "record.cue", availablePaths: ["sample.wav"])[1]
        let folder = try ScopedFolder(root)
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.CueLyrics.\(UUID())")!)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        let snapshot = try await player.readMetadata(for: track)
        XCTAssertEqual(snapshot.duration, 5, accuracy: 0.01)
        let document = try await LyricsView.readDocument(track: track, folder: folder, snapshot: snapshot)
        XCTAssertEqual(document.lines.map(\.text), ["Selected phrase"])
        XCTAssertEqual(document.lines.map(\.time), [2])
    }

    @MainActor func testSynchronizationUsesDecodedVBRDurationAndAvoidsPaidFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lyrics-repair-vbr", withExtension: "mp3"))
        let url = root.appendingPathComponent("song.mp3"); try FileManager.default.copyItem(at: fixture, to: url)
        let folder = try ScopedFolder(root), track = try XCTUnwrap(AudioTrack(relativePath: "song.mp3"))
        let snapshot = try await MetadataService.read(url: url, folder: folder)
        let duration = try await LyricsAudioPreparation.duration(track: track, folder: folder, expected: snapshot.fingerprint)
        XCTAssertLessThan(snapshot.duration, 1, "The fixture must reproduce the rejected container estimate")
        XCTAssertGreaterThan(duration, 4)
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"),
            cache: MetadataLookupCache(directory: root.appendingPathComponent("cache")), transport: DecodedDurationCatalog(duration: duration))
        let result = try await LyricsSynchronizationView.synchronize(client: client, query: MetadataSearch(title: "Song", artist: "Artist", album: "Album"),
            track: track, folder: folder, snapshot: snapshot, lyrics: "Hello\nAgain", offline: false) {
                XCTFail("The valid free catalog match must never prepare audio for a paid analysis")
            }
        XCTAssertEqual(result.value.source, .lrclib)
        XCTAssertEqual(LyricsDocument(text: result.value.text).lines.map(\.time), [0.1, 3.9])
    }

    @MainActor func testMetadataEditorUsesDecodedDurationForPhraseBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lyrics-repair-vbr", withExtension: "mp3"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("song.mp3"))
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.EditDuration.\(UUID())")!)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        let track = try XCTUnwrap(player.current)
        let snapshot = try await MetadataEditorView.readSnapshot(player: player, track: track)
        XCTAssertGreaterThan(snapshot.duration, 4)
        let draft = LyricsDraft(text: "[00:00.10]Hello\n[00:03.90]Again")
        let edited = try draft.replacing(draft.lines[1].id, text: "Again!", time: 3.9, duration: snapshot.duration)
        XCTAssertEqual(LyricsDocument(text: edited).lines.last?.time, 3.9)
    }

    @MainActor func testCueMetadataUsesDecodedBoundsWithAnInaccurateContainerDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lyrics-repair-vbr", withExtension: "mp3"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("song.mp3"))
        let cue = "FILE \"song.mp3\" MP3\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00\nTRACK 03 AUDIO\nINDEX 01 00:03:00"
        try cue.write(to: root.appendingPathComponent("record.cue"), atomically: true, encoding: .utf8)
        try "[00:01.10]Selected\n[00:03.50]Next".write(to: root.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
        let player = PlaybackController(defaults: UserDefaults(suiteName: "SonoraTests.CueVBR.\(UUID())")!)
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        let track = try XCTUnwrap(player.queue.tracks.first { $0.cue?.number == 2 })
        let snapshot = try await player.readMetadata(for: track)
        XCTAssertEqual(snapshot.duration, 2, accuracy: 0.01)
        let document = try await LyricsView.readDocument(track: track, folder: player.folderAccess(for: track), snapshot: snapshot)
        XCTAssertEqual(document.lines.map(\.text), ["Selected"])
        XCTAssertEqual(try XCTUnwrap(document.lines.first?.time), 0.1, accuracy: 0.01)
    }

}
