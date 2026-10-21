import AVFAudio
import Foundation
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class AlbumInterpretationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    private func reading() throws -> LyricsInterpretation {
        try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"The record moves from departure to homecoming.","model":"gpt-6-astra","effort":"medium"}"#.utf8))
    }
    private func config(_ defaults: UserDefaults, root: URL) -> MetadataAssistantSettings {
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        return MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: UUID().uuidString), cache: .init(directory: root.appendingPathComponent("metadata")))
    }
    func testLibrarySiblingsOutsideQueueAreCollectedWithOrderedLyricsAndTagsAndRestoreOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AlbumTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(false, forKey: "prepareQueueAudio"); defaults.set(false, forKey: "prepareQueueTranslation")
        let folderURL = root.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = try ScopedFolder(folderURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        for index in 1...3 {
            let url = folderURL.appendingPathComponent("\(index).wav")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)); buffer.frameLength = 8000
                for i in 0..<8000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.2)) * Float(index) * 0.1 }
                try file.write(from: buffer)
            }
            _ = try await MetadataService.save(url: url, folder: folder, expected: FileFingerprint(url), patch: .init(values: [
                .title: "Song \(index)", .album: "Journeys", .artist: index == 2 ? "Guest" : "Travellers", .albumArtist: "Travellers",
                .genre: "Rock", .trackNumber: String(index), .discNumber: "1"
            ]))
            if index < 3 {
                try "[00:00]Full verse \(index)\n[00:00.50]Returning home.".write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            }
        }
        let cache = MusicToolsCache(root: root.appendingPathComponent("tools")), settings = config(defaults, root: root), response = try reading()
        var received: [AlbumInterpretationInput] = [], characterized: [String] = []
        let albums = AlbumInterpretationStore(settings: settings, cache: cache) { album, language, _ in
            XCTAssertEqual(language, "es"); received.append(album); return response
        }
        let characterValue = try JSONDecoder().decode(AudioCharacter.self, from: Data(#"{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Indie Rock","score":0.3}],"moods":{"happy":0.2,"sad":0.8,"relaxed":0.9,"aggressive":0.1}}"#.utf8))
        let characters = AudioCharacterStore(settings: settings, cache: cache) { track, _, _, _ in characterized.append(track.filename); return characterValue }
        let meanings = LyricInterpretationStore(settings: settings) { _, _, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }; return response
        }
        let player = PlaybackController(defaults: defaults, musicTools: MusicToolsStore(cache: cache), lyricInterpretations: meanings,
                                        albumInterpretations: albums, audioCharacter: characters)
        defer { player.stop() }
        let tracks = try await FolderScanService.scan(folder)
        try player.library.register(folder, tracks: tracks)
        try await wait { !player.library.isIndexing }
        let selected = try XCTUnwrap(player.library.state.songs.values.first { $0.title == "Song 3" })
        player.playSongs([selected.id])
        try await wait { received.count == 1 && albums.results.count == 1 }
        XCTAssertEqual(player.queue.tracks.count, 1)
        XCTAssertEqual(received[0].tracks.map(\.context.title), ["Song 1", "Song 2", "Song 3"])
        XCTAssertEqual(received[0].tracks.map(\.lyrics), ["Full verse 1\nReturning home.", "Full verse 2\nReturning home.", ""])
        XCTAssertEqual(received[0].tracks[1].context.artist, "Guest")
        XCTAssertTrue(received[0].tracks.allSatisfy { $0.context.styles == ["Rock---Indie Rock"] && $0.context.moods == ["sad", "relaxed"] && $0.genre == "Rock" })
        XCTAssertEqual(Set(characterized), ["1.wav", "2.wav", "3.wav"])
        XCTAssertEqual(received[0].missingLyrics, 1)
        let album = try XCTUnwrap(player.currentAlbum)
        let other = try XCTUnwrap(player.library.state.songs.values.first { $0.title == "Song 1" })
        player.playSongs([other.id])
        try await wait { player.current?.relativePath == "1.wav" && !player.isPreparing }
        XCTAssertEqual(player.currentAlbum?.id, album.id)
        XCTAssertEqual(player.currentAlbum?.revision, album.revision, "Playback formatting must not invalidate the album")
        XCTAssertEqual(received.count, 1, "Changing songs in the album must reuse the same result")
        player.pause()
        settings.offline = true
        let reopened = AlbumInterpretationStore(settings: settings, cache: cache) { _, _, _ in XCTFail("Offline restoration must not call Codex"); return response }
        let saved = try await reopened.load(album, language: "es", character: true, cachedOnly: true) { _, _ in XCTFail("Offline restoration must not reread audio"); throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(saved.album, received[0])
        settings.offline = false
        try "[00:00]Edited words\n[00:00.50]A different ending.".write(to: folderURL.appendingPathComponent("1.lrc"), atomically: true, encoding: .utf8)
        try await player.refreshAlbum(album, language: "es", character: true)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[1].tracks[0].lyrics, "Edited words\nA different ending.")
        XCTAssertFalse(player.isPlaying)
    }

    func testRefreshCoalescesAfterActiveWorkAndFailureKeepsPriorReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AlbumRefresh.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var collection = MusicCollection(); collection.sources = [.init(id: "source", name: "Music", bookmark: Data())]
        collection.upsert([.init(sourceID: "source", relativePath: "one.wav", tags: [.album: "A", .artist: "B"])])
        let group = try XCTUnwrap(collection.groups(byAlbum: true).first)
        let album = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { collection.songs[$0] })
        let corpus = AlbumInterpretationInput(title: "A", artist: "B", tracks: [.init(context: .init(title: "One"), lyrics: "Full text")])
        let response = try reading()
        var calls: [Bool] = [], gate: CheckedContinuation<LyricsInterpretation, Error>?
        defer { gate?.resume(returning: response) }
        let store = AlbumInterpretationStore(settings: config(defaults, root: root), cache: MusicToolsCache(root: root)) { _, _, refresh in
            calls.append(refresh)
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        let collect: AlbumInterpretationStore.Collector = { _, _ in corpus }
        let first = Task { try await store.load(album, language: "es", character: false, collect: collect) }
        try await wait { gate != nil }
        let refresh = Task { try await store.load(album, language: "es", character: false, refresh: true, collect: collect) }
        let joined = Task { try await store.load(album, language: "es", character: false, refresh: true, collect: collect) }
        await Task.yield(); gate?.resume(returning: response); gate = nil
        _ = try await first.value
        try await wait { calls.count == 2 && gate != nil }
        XCTAssertEqual(calls, [false, true])
        gate?.resume(throwing: URLError(.cannotConnectToHost)); gate = nil
        do { _ = try await refresh.value; XCTFail() } catch { }
        do { _ = try await joined.value; XCTFail() } catch { }
        let preserved = try await store.load(album, language: "es", character: false, collect: collect)
        XCTAssertEqual(preserved.interpretation, response)
    }

    func testResetSkipsOldAlbumReadingButReusesCorpusAndKeepsOtherCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AlbumReset.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var collection = MusicCollection(); collection.sources = [.init(id: "source", name: "Music", bookmark: Data())]
        collection.upsert([.init(sourceID: "source", relativePath: "one.wav", tags: [.album: "A", .artist: "B"])])
        let group = try XCTUnwrap(collection.groups(byAlbum: true).first)
        let album = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { collection.songs[$0] })
        let corpus = AlbumInterpretationInput(title: "A", artist: "B", tracks: [.init(context: .init(title: "One"), lyrics: "Full text")])
        let cache = MusicToolsCache(root: root), settings = config(defaults, root: root)
        let oldKey = "codex-album-v1:\(settings.endpoint):es:\(AudioCharacter.version):false:\(album.id):\(album.revision)"
        let corpusKey = "album-corpus:codex-album-v1:\(AudioCharacter.version):false:\(album.id):\(album.revision)"
        let previous = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"Previous album reading.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
        try await cache.write(AlbumInterpretationStore.Prepared(album: corpus, interpretation: previous), key: oldKey)
        try await cache.write(corpus, key: corpusKey)
        let sentinel = ["kept": "yes"]
        try await cache.write(sentinel, key: "codex-translation-v1:fixture")
        try await cache.write(sentinel, key: "manual-markers", personal: true)
        let response = try reading()
        var calls = 0
        let store = AlbumInterpretationStore(settings: settings, cache: cache) { input, _, _ in
            XCTAssertEqual(input, corpus); calls += 1; return response
        }
        let result = try await store.load(album, language: "es", character: false) { _, _ in
            XCTFail("The reset must reuse the collected lyrics and metadata"); return corpus
        }
        XCTAssertEqual(result.interpretation.effort, "medium")
        XCTAssertEqual(calls, 1)
        let reopened = AlbumInterpretationStore(settings: settings, cache: cache) { _, _, _ in
            XCTFail("The reset must happen once, not on every launch"); return response
        }
        let saved = try await reopened.load(album, language: "es", character: false, cachedOnly: true) { _, _ in
            XCTFail("Cached results must not recollect the album"); return corpus
        }
        XCTAssertEqual(saved.interpretation, response)
        let translation = try await cache.read([String: String].self, key: "codex-translation-v1:fixture")
        let markers = try await cache.read([String: String].self, key: "manual-markers", personal: true)
        XCTAssertEqual(translation, sentinel); XCTAssertEqual(markers, sentinel)
    }
}
