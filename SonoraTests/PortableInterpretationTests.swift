import Foundation
import SFBAudioEngine
import SonoraCore
import XCTest
@testable import Sonora

private actor PortableMeaningHTTP: MetadataLookupTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        calls += 1
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let text = body?["language"] as? String == "en" ? "English song reading." : "About this song.\n\nIts second paragraph."
        return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: [
            "explanation": text, "model": "gpt-6-astra", "effort": "medium"
        ]), status: 200, contentType: "application/json")
    }
}

@MainActor final class PortableInterpretationTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try FileManager.default.removeItem(at: root)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    private func reading(_ text: String) throws -> LyricsInterpretation {
        try JSONDecoder().decode(LyricsInterpretation.self, from: JSONSerialization.data(withJSONObject: [
            "explanation": text, "model": "gpt-6-astra", "effort": "medium"
        ]))
    }
    private func player(_ name: String, offline: Bool, characterAnalyzer: AudioCharacterStore.Analyzer? = nil, diskMeanings: Bool = false, calls: @escaping () -> Void) throws -> (PlaybackController, MetadataAssistantSettings) {
        let suite = "PortableMeaning.\(UUID())"; suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for key in ["prepareQueueAudio", "prepareQueueCharacter", "prepareQueueTranslation", "prepareQueueMeaning"] { defaults.set(false, forKey: key) }
        if name != "handwritten" { defaults.set("http://127.0.0.1:9/\(name)", forKey: "metadata.endpoint") }
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: UUID().uuidString),
                                                cache: .init(directory: root.appendingPathComponent(name + "-metadata")))
        settings.offline = offline
        let transport = PortableMeaningHTTP()
        let meanings = LyricInterpretationStore(settings: settings) { document, language, context, mode in
            if diskMeanings {
                if mode != .cachedOnly { calls() }
                let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: "")
                return try await LyricsInterpretationClient(connection: connection, cache: settings.cache, transport: transport)
                    .interpret(lyrics: document.lines.map(\.text).joined(separator: "\n"), language: language, context: context,
                               offline: mode == .cachedOnly, refresh: mode == .refresh)
            }
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            calls(); return try self.reading(language == "en" ? "English song reading." : "About this song.\n\nIts second paragraph.")
        }
        let albums = AlbumInterpretationStore(settings: settings, cache: MusicToolsCache(root: root.appendingPathComponent(name + "-tools"))) { _, language, _ in
            calls(); return try self.reading(language == "en" ? "English album reading." : "About the album.")
        }
        return (PlaybackController(defaults: defaults, musicTools: MusicToolsStore(cache: MusicToolsCache(root: root.appendingPathComponent(name + "-audio"))),
                                   lyricInterpretations: meanings, albumInterpretations: albums, audioCharacter: AudioCharacterStore(settings: settings, cache: MusicToolsCache(root: root.appendingPathComponent(name + "-character")), analyzer: characterAnalyzer)), settings)
    }
    private func fixture(_ ext: String = "mp3") throws -> URL {
        let folder = root.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("song." + ext)
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: ext)), to: url)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.title = "Fixture"; file.metadata.artist = "Artist"; file.metadata.albumArtist = "Artist"; file.metadata.albumTitle = "Album"
        file.metadata.lyrics = "Hello\nWorld"; try file.writeMetadata()
        return url
    }
    private func register(_ folder: URL, player: PlaybackController) async throws -> (CollectionSong, AlbumPreparationRequest) {
        try player.library.register(ScopedFolder(folder), tracks: FolderScanner.scan(folder))
        try await wait { !player.library.isIndexing }
        let song = try XCTUnwrap(player.library.state.sortedSongs().first)
        let group = try XCTUnwrap(player.library.state.groups(byAlbum: true).first)
        return (song, AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { player.library.state.songs[$0] }))
    }
    private let payload = #"{"version":1,"language":"es","title":"Fixture","artist":"Artist","album":"Album","lyricsDigest":"35c6b9f66dceb6cf8f733d08689564e420e18eb40250d9435352617c027f36d6","interpretation":{"explanation":"Saved from another installation.","model":"gpt-6-astra","effort":"medium"}}"#
    private let albumPayload = #"{"version":1,"language":"es","title":"Album","artist":"Artist","trackCount":3,"missingLyrics":1,"interpretation":{"explanation":"Saved album reading.","model":"gpt-6-astra","effort":"medium"}}"#
    private let context = LyricsInterpretationContext(title: "Fixture", artist: "Artist", album: "Album")
    private let document = LyricsDocument(text: "Hello\nWorld")

    func testCachedInterpretationsExportAndRestoreAfterMovingAndImportingMP3() async throws {
        let source = try fixture()
        try ID3ExportTags.write(["KEEP_ME": ["first", "second"]], to: source)
        let before = try Data(contentsOf: source)
        var generated = 0
        let (original, _) = try player("original", offline: false) { generated += 1 }; defer { original.stop() }
        let (song, album) = try await register(source.deletingLastPathComponent(), player: original)
        _ = try await original.lyricInterpretations.load(document, language: "es", context: context)
        _ = try await original.albumInterpretations.load(album, language: "es", character: false) { _, _ in
            AlbumInterpretationInput(title: "Album", artist: "Artist", tracks: [.init(context: self.context, lyrics: "Hello\nWorld")])
        }
        XCTAssertEqual(generated, 2)
        let id = try XCTUnwrap(original.library.createPlaylist("Travel")); original.library.add([song.id], to: id)
        let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let exported = try await original.exportPlaylist(id, to: destination, name: "Travel", format: .mp3)
        XCTAssertEqual(generated, 2, "Export must use saved interpretations only")
        let moved = root.appendingPathComponent("moved"); try FileManager.default.moveItem(at: exported, to: moved)
        let listURL = moved.appendingPathComponent("Travel.m3u8")
        let list = try await PlaylistExchange.read(listURL)
        let mp3 = moved.appendingPathComponent(try XCTUnwrap(list.content.entries.first).path)
        let tags = try ID3ExportTags.read(from: mp3)
        XCTAssertNotNil(tags["SONORA_SONG_ABOUT:es"]); XCTAssertNotNil(tags["SONORA_ALBUM_ABOUT:es"])
        XCTAssertEqual(tags["KEEP_ME"], ["first", "second"])
        func payload(_ data: Data) -> Data {
            let start = data.starts(with: Data("ID3".utf8)) ? 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) } : 0
            let end = data.count >= 128 && data.suffix(128).starts(with: Data("TAG".utf8)) ? data.count - 128 : data.count
            return data.subdata(in: start..<end)
        }
        XCTAssertEqual(payload(before), payload(try Data(contentsOf: mp3)), "Embedding text must not recompress MP3 audio")
        XCTAssertEqual(try Data(contentsOf: source), before)
        var newRequests = 0
        let (imported, _) = try player("fresh", offline: true) { newRequests += 1 }; defer { imported.stop() }
        let report = try await PlaylistExchange.importPlaylist(list, folder: moved, library: imported.library)
        try await wait { !imported.library.isIndexing }
        XCTAssertEqual(report.imported, 1)
        await imported.lyricInterpretations.restore(document, language: "es", context: context)
        let key = imported.lyricInterpretations.key(document, language: "es", context: context)
        XCTAssertEqual(imported.lyricInterpretations.results[key]?.explanation, "About this song.\n\nIts second paragraph.")
        let group = try XCTUnwrap(imported.library.state.groups(byAlbum: true).first)
        let restoredAlbum = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { imported.library.state.songs[$0] })
        do {
            let result = try await imported.albumInterpretations.load(restoredAlbum, language: "es", character: false, cachedOnly: true) { _, _ in
                XCTFail("Recovery must not collect album lyrics"); throw MetadataLookupError.notCached
            }
            XCTAssertEqual(result.interpretation.explanation, "About the album.")
        } catch { XCTFail("Album recovery failed: \(error)") }
        XCTAssertEqual(newRequests, 0, "Import must not contact Codex")
    }

    func testHandWrittenID3ReadingRestoresWithoutEndpointAndIgnoresWrongLanguageAndEditedLyrics() async throws {
        let url = try fixture()
        let text = payload.replacingOccurrences(of: "Saved from another installation.", with: "Una canción de otoño: corazón y alegría.")
        try ID3ExportTags.write(["SONORA_SONG_ABOUT": [text]], to: url)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.title = " Fixture "; file.metadata.artist = " Artist "; file.metadata.albumTitle = " Album "
        try file.writeMetadata()
        var requests = 0
        let (player, _) = try player("handwritten", offline: true) { requests += 1 }; defer { player.stop() }
        _ = try await register(url.deletingLastPathComponent(), player: player)
        await player.lyricInterpretations.restore(document, language: "es", context: context)
        XCTAssertEqual(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "es", context: context)]?.explanation, "Una canción de otoño: corazón y alegría.")
        await player.lyricInterpretations.restore(document, language: "en", context: context)
        XCTAssertNil(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "en", context: context)])
        let edited = LyricsDocument(text: "Different words")
        await player.lyricInterpretations.restore(edited, language: "es", context: context)
        XCTAssertNil(player.lyricInterpretations.results[player.lyricInterpretations.key(edited, language: "es", context: context)])
        XCTAssertEqual(requests, 0)
    }
    func testInvalidOrUnrelatedTagsNeverRestoreAndDoNotPreventImport() async throws {
        let url = try fixture()
        let invalid: [[String]] = [["{"], [payload.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")],
                                  [payload.replacingOccurrences(of: "gpt-6-astra", with: "other-model")],
                                  [payload.replacingOccurrences(of: "Fixture", with: "Another song")],
                                  [String(repeating: "x", count: 131073)], [payload, payload],
                                  [payload.replacingOccurrences(of: "Saved from another installation.", with: #"\u0000"#)]]
        var requests = 0
        for (index, values) in invalid.enumerated() {
            try ID3ExportTags.write(["SONORA_SONG_ABOUT": values], to: url)
            let (player, _) = try player("invalid-\(index)", offline: true) { requests += 1 }
            _ = try await register(url.deletingLastPathComponent(), player: player)
            await player.lyricInterpretations.restore(document, language: "es", context: context)
            XCTAssertNil(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "es", context: context)])
            XCTAssertEqual(player.library.state.songs.count, 1)
            player.stop()
        }
        XCTAssertEqual(requests, 0)
    }

    func testActualEditedLyricsAndAlbumTagsCannotReuseOldEmbeddedReading() async throws {
        let url = try fixture()
        try ID3ExportTags.write(["SONORA_SONG_ABOUT": [payload], "SONORA_ALBUM_ABOUT": [albumPayload]], to: url)
        try "[00:00]Edited lyrics".write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        let (player, _) = try player("edited", offline: true) { XCTFail("Offline import must not generate a reading") }; defer { player.stop() }
        let (song, _) = try await register(url.deletingLastPathComponent(), player: player)
        await player.lyricInterpretations.restore(document, language: "es", context: context)
        XCTAssertNil(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "es", context: context)])
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url); file.metadata.albumTitle = "Different album"; try file.writeMetadata()
        await player.library.refresh(track: try XCTUnwrap(song.audioTrack), source: song.sourceID, folder: try ScopedFolder(url.deletingLastPathComponent()))
        let group = try XCTUnwrap(player.library.state.groups(byAlbum: true).first)
        let album = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { player.library.state.songs[$0] })
        let result = try await player.albumInterpretations.cachedResult(album, language: "es", character: false)
        XCTAssertNil(result)
    }

    func testExplicitRefreshReplacesImportedReadingsAndNextExportUsesNewText() async throws {
        let url = try fixture()
        try ID3ExportTags.write(["SONORA_SONG_ABOUT": [payload], "SONORA_ALBUM_ABOUT": [albumPayload]], to: url)
        let before = try Data(contentsOf: url)
        var requests = 0
        let (player, settings) = try player("refresh", offline: true) { requests += 1 }; defer { player.stop() }
        let (song, album) = try await register(url.deletingLastPathComponent(), player: player)
        let initial = try await player.albumInterpretations.cachedResult(album, language: "es", character: false)
        XCTAssertEqual(initial?.trackCount, 3); XCTAssertEqual(initial?.missingLyrics, 1)
        await player.lyricInterpretations.restore(document, language: "es", context: context)
        settings.offline = false
        let meaning = try await player.lyricInterpretations.load(document, language: "es", context: context, refresh: true)
        let updated = try await player.albumInterpretations.load(album, language: "es", character: false, refresh: true) { _, _ in
            AlbumInterpretationInput(title: "Album", artist: "Artist", tracks: [.init(context: self.context, lyrics: "Hello\nWorld")])
        }
        XCTAssertEqual(meaning.explanation, "About this song.\n\nIts second paragraph.")
        XCTAssertEqual(updated.interpretation.explanation, "About the album.")
        XCTAssertEqual(requests, 2)
        let id = try XCTUnwrap(player.library.createPlaylist("Updated")); player.library.add([song.id], to: id)
        let exported = try await player.exportPlaylist(id, to: root, name: "Updated", format: .mp3)
        let entry = try XCTUnwrap(M3UPlaylist.decode(Data(contentsOf: exported.appendingPathComponent("Updated.m3u8")), utf8Only: true).entries.first)
        let saved = try MetadataService.snapshot(exported.appendingPathComponent(entry.path)).portableInterpretations
        XCTAssertEqual(saved.songs["es"]?.interpretation.explanation, meaning.explanation)
        XCTAssertEqual(saved.albums["es"]?.interpretation.explanation, updated.interpretation.explanation)
        XCTAssertEqual(requests, 2); XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testWAVConversionCarriesBothReadingsAndUnknownAlbumDoesNotBlockExport() async throws {
        let url = try fixture("wav")
        let (player, _) = try player("wav", offline: false) { }; defer { player.stop() }
        let (song, album) = try await register(url.deletingLastPathComponent(), player: player)
        _ = try await player.lyricInterpretations.load(document, language: "es", context: context)
        _ = try await player.albumInterpretations.load(album, language: "es", character: false) { _, _ in
            AlbumInterpretationInput(title: "Album", artist: "Artist", tracks: [.init(context: self.context, lyrics: "Hello\nWorld")])
        }
        let id = try XCTUnwrap(player.library.createPlaylist("Converted")); player.library.add([song.id], to: id)
        let folder = try await player.exportPlaylist(id, to: root, name: "Converted", format: .mp3)
        let entry = try XCTUnwrap(M3UPlaylist.decode(Data(contentsOf: folder.appendingPathComponent("Converted.m3u8")), utf8Only: true).entries.first)
        let saved = try MetadataService.snapshot(folder.appendingPathComponent(entry.path)).portableInterpretations
        XCTAssertEqual(saved.songs["es"]?.interpretation.explanation, "About this song.\n\nIts second paragraph.")
        XCTAssertEqual(saved.albums["es"]?.interpretation.explanation, "About the album.")
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url); file.metadata.albumTitle = nil; try file.writeMetadata()
        let scoped = try ScopedFolder(url.deletingLastPathComponent())
        await player.library.refresh(track: try XCTUnwrap(song.audioTrack), source: song.sourceID, folder: scoped)
        let group = try XCTUnwrap(player.library.state.groups(byAlbum: true).first)
        let unknown = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { player.library.state.songs[$0] })
        _ = try await player.albumInterpretations.load(unknown, language: "es", character: false) { _, _ in
            AlbumInterpretationInput(title: unknown.title, artist: unknown.artist, tracks: [.init(context: .init(title: "Fixture"), lyrics: "Hello\nWorld")])
        }
        _ = try await player.exportPlaylist(id, to: root, name: "Unknown", format: .mp3)
    }

    func testExportDoesNotJoinUnfinishedAudioClassification() async throws {
        let url = try fixture()
        var gate: CheckedContinuation<AudioCharacter, Error>?
        let character = try JSONDecoder().decode(AudioCharacter.self, from: Data(#"{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Indie Rock","score":0.7}],"moods":{"happy":0.2,"sad":0.8,"relaxed":0.9,"aggressive":0.1}}"#.utf8))
        let (player, _) = try player("busy", offline: false, characterAnalyzer: { _, _, _, _ in
            try await withCheckedThrowingContinuation { gate = $0 }
        }) { XCTFail("Export must not request an interpretation") }
        defer { player.stop() }
        let (song, _) = try await register(url.deletingLastPathComponent(), player: player)
        let track = try XCTUnwrap(song.audioTrack), folder = try ScopedFolder(url.deletingLastPathComponent())
        let analysis = Task { try await player.audioCharacter.load(track: track, folder: folder, expected: FileFingerprint(url)) }
        try await wait { gate != nil }
        let id = try XCTUnwrap(player.library.createPlaylist("Busy")); player.library.add([song.id], to: id)
        var finished = false
        let export = Task { defer { finished = true }; return try await player.exportPlaylist(id, to: root, name: "Busy", format: .mp3) }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        let completedBeforeClassifier = finished
        gate?.resume(returning: character); gate = nil
        let analysisResult = await analysis.result, exportResult = await export.result
        XCTAssertTrue(completedBeforeClassifier, "Export must read completed bindings only, without waiting for classification")
        _ = try analysisResult.get(); _ = try exportResult.get()
    }

    func testAllDiskCachedLanguagesExportAndImportIntoSeparateOfflineEntries() async throws {
        let url = try fixture()
        var calls = 0
        let (original, settings) = try player("multilingual", offline: false, diskMeanings: true) { calls += 1 }
        defer { original.stop() }
        let (song, album) = try await register(url.deletingLastPathComponent(), player: original)
        for language in ["es", "en"] {
            _ = try await original.lyricInterpretations.load(document, language: language, context: context)
            _ = try await original.albumInterpretations.load(album, language: language, character: false) { _, _ in
                AlbumInterpretationInput(title: "Album", artist: "Artist", tracks: [.init(context: self.context, lyrics: "Hello\nWorld")])
            }
        }
        let id = try XCTUnwrap(original.library.createPlaylist("Languages")); original.library.add([song.id], to: id)
        // A new player has no in-memory readings and must restore both languages from disk.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(suites.last)))
        let exportTransport = PortableMeaningHTTP()
        let restoredMeanings = LyricInterpretationStore(settings: settings) { document, language, context, mode in
            let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: "")
            return try await LyricsInterpretationClient(connection: connection, cache: settings.cache, transport: exportTransport)
                .interpret(lyrics: document.lines.map(\.text).joined(separator: "\n"), language: language, context: context,
                           offline: mode == .cachedOnly, refresh: mode == .refresh)
        }
        let reopened = PlaybackController(defaults: defaults, lyricInterpretations: restoredMeanings,
            albumInterpretations: AlbumInterpretationStore(settings: settings, cache: MusicToolsCache(root: root.appendingPathComponent("multilingual-tools"))))
        defer { reopened.stop() }
        XCTAssertTrue(reopened.lyricInterpretations.results.isEmpty)
        XCTAssertTrue(reopened.albumInterpretations.results.isEmpty)
        let exported = try await reopened.exportPlaylist(id, to: root, name: "Languages", format: .mp3)
        let list = try await PlaylistExchange.read(exported.appendingPathComponent("Languages.m3u8"))
        let output = exported.appendingPathComponent(try XCTUnwrap(list.content.entries.first).path)
        let tags = try ID3ExportTags.read(from: output)
        for name in ["SONORA_SONG_ABOUT:es", "SONORA_SONG_ABOUT:en", "SONORA_ALBUM_ABOUT:es", "SONORA_ALBUM_ABOUT:en"] {
            XCTAssertNotNil(tags[name], "Missing saved language: \(name)")
        }
        XCTAssertNil(tags["SONORA_SONG_ABOUT:fr"])
        let exportRequests = await exportTransport.calls
        XCTAssertEqual(exportRequests, 0, "Export must not generate any missing language")
        XCTAssertEqual(calls, 4)
        var importedCalls = 0
        let (fresh, _) = try player("multi-import", offline: true) { importedCalls += 1 }; defer { fresh.stop() }
        _ = try await PlaylistExchange.importPlaylist(list, folder: exported, library: fresh.library)
        try await wait { !fresh.library.isIndexing }
        let group = try XCTUnwrap(fresh.library.state.groups(byAlbum: true).first)
        let importedAlbum = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { fresh.library.state.songs[$0] })
        for (language, songText, albumText) in [("es", "About this song.\n\nIts second paragraph.", "About the album."),
                                               ("en", "English song reading.", "English album reading.")] {
            await fresh.lyricInterpretations.restore(document, language: language, context: context)
            XCTAssertEqual(fresh.lyricInterpretations.results[fresh.lyricInterpretations.key(document, language: language, context: context)]?.explanation, songText)
            let reading = try? await fresh.albumInterpretations.load(importedAlbum, language: language, character: false, cachedOnly: true) { _, _ in
                XCTFail("Import must not collect album lyrics"); throw MetadataLookupError.notCached
            }
            XCTAssertEqual(reading?.interpretation.explanation, albumText)
        }
        XCTAssertEqual(importedCalls, 0)
    }

    func testRefreshingOneLanguageKeepsOtherEmbeddedLanguagesAndLegacyReading() async throws {
        let url = try fixture()
        let englishSong = payload.replacingOccurrences(of: "\"es\"", with: "\"en\"")
            .replacingOccurrences(of: "Saved from another installation.", with: "Existing English song.")
        let englishAlbum = albumPayload.replacingOccurrences(of: "\"es\"", with: "\"en\"")
            .replacingOccurrences(of: "Saved album reading.", with: "Existing English album.")
        try ID3ExportTags.write(["SONORA_SONG_ABOUT": [payload], "SONORA_ALBUM_ABOUT": [albumPayload],
            "SONORA_SONG_ABOUT:en": [englishSong], "SONORA_ALBUM_ABOUT:en": [englishAlbum], "UNRELATED": ["keep"]], to: url)
        let before = try Data(contentsOf: url)
        var calls = 0
        let (player, _) = try player("replace-es", offline: false) { calls += 1 }; defer { player.stop() }
        let (song, album) = try await register(url.deletingLastPathComponent(), player: player)
        _ = try await player.lyricInterpretations.load(document, language: "es", context: context, refresh: true)
        _ = try await player.albumInterpretations.load(album, language: "es", character: false, refresh: true) { _, _ in
            AlbumInterpretationInput(title: "Album", artist: "Artist", tracks: [.init(context: self.context, lyrics: "Hello\nWorld")])
        }
        let id = try XCTUnwrap(player.library.createPlaylist("Keep languages")); player.library.add([song.id], to: id)
        let exported = try await player.exportPlaylist(id, to: root, name: "Keep languages", format: .mp3)
        let list = try await PlaylistExchange.read(exported.appendingPathComponent("Keep languages.m3u8"))
        let output = exported.appendingPathComponent(try XCTUnwrap(list.content.entries.first).path)
        let tags = try ID3ExportTags.read(from: output)
        func explanation(_ key: String) throws -> String? {
            let text = try XCTUnwrap(tags[key]?.first)
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return (object?["interpretation"] as? [String: Any])?["explanation"] as? String
        }
        XCTAssertEqual(try explanation("SONORA_SONG_ABOUT:es"), "About this song.\n\nIts second paragraph.")
        XCTAssertEqual(try explanation("SONORA_ALBUM_ABOUT:es"), "About the album.")
        XCTAssertEqual(try explanation("SONORA_SONG_ABOUT:en"), "Existing English song.")
        XCTAssertEqual(try explanation("SONORA_ALBUM_ABOUT:en"), "Existing English album.")
        XCTAssertEqual(tags["UNRELATED"], ["keep"])
        XCTAssertEqual(try Data(contentsOf: url), before); XCTAssertEqual(calls, 2)
    }

    func testLanguageSuffixMustMatchPayloadAndModernFieldsWinOverLegacy() async throws {
        let url = try fixture()
        let modern = payload.replacingOccurrences(of: "Saved from another installation.", with: "Current Spanish reading.")
        try ID3ExportTags.write(["SONORA_SONG_ABOUT": [payload], "SONORA_SONG_ABOUT:es": [modern],
                                 "SONORA_SONG_ABOUT:fr": [modern]], to: url)
        let (player, _) = try player("suffix", offline: true) { XCTFail("Recovery must not generate text") }; defer { player.stop() }
        _ = try await register(url.deletingLastPathComponent(), player: player)
        await player.lyricInterpretations.restore(document, language: "es", context: context)
        XCTAssertEqual(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "es", context: context)]?.explanation, "Current Spanish reading.")
        await player.lyricInterpretations.restore(document, language: "fr", context: context)
        XCTAssertNil(player.lyricInterpretations.results[player.lyricInterpretations.key(document, language: "fr", context: context)])
    }

}
