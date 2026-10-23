import AVFAudio
import SFBAudioEngine
import SonoraCore
import UniformTypeIdentifiers
import XCTest
@testable import Sonora

@MainActor final class ExternalAudioFileTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var players: [PlaybackController] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "SonoraTests.OpenAudio.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for key in ["prepareQueueAudio", "prepareQueueCharacter", "prepareQueueTranslation", "prepareQueueMeaning"] { defaults.set(false, forKey: key) }
    }
    override func tearDown() async throws {
        for player in players { player.stop(); player.library.cancelIndexing() }
        players = []
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func player() -> PlaybackController {
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("managed"), activateSession: {})
        players.append(player); return player
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "File playback did not reach the expected state")
    }
    private func audio(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.1) } }
        // AVAudioFile infers CAF for an uppercase .WAV extension. Create a
        // genuine RIFF first, then rename it to exercise case-insensitive input.
        let writingURL = url.deletingPathExtension().appendingPathExtension("wav")
        try autoreleasepool { try AVAudioFile(forWriting: writingURL, settings: format.settings).write(from: buffer) }
        XCTAssertEqual(try Data(contentsOf: writingURL).prefix(4), Data("RIFF".utf8))
        if writingURL != url { try FileManager.default.moveItem(at: writingURL, to: url) }
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        file.metadata.title = "Shared song"; file.metadata.artist = "Shared artist"; file.metadata.albumTitle = "Shared album"
        file.metadata.genre = "Rock"; file.metadata.bpm = 123; file.metadata.lyrics = "[00:00.10]First\n[00:01.00]Last"
        let cover = try AudioFile(readingPropertiesAndMetadataFrom: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture-cover", withExtension: "flac"))).metadata.attachedPictures.first!
        file.metadata.attachPicture(cover); try file.writeMetadata()
        return url
    }

    func testBundleAdvertisesAudioViewingAndOpeningInPlace() throws {
        let documents = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertTrue(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.audio") == true && $0["CFBundleTypeRole"] as? String == "Viewer" })
        XCTAssertEqual(Bundle.main.infoDictionary?["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        let advertised = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for ext in FolderScanner.defaultExtensions {
            let audio = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: .audio)
            XCTAssertFalse(audio.isEmpty, "Missing audio type for .\(ext)")
            XCTAssertTrue(audio.contains { advertised.contains($0.identifier) || $0.conforms(to: .audio) && advertised.contains("public.audio") })
        }
    }
    func testOpensOnlyChosenOriginalWithFullMetadataAndNoLibraryImport() async throws {
        let url = try audio("outside/Chosen.WAV"), bytes = try Data(contentsOf: url)
        _ = try audio("outside/Other.wav")
        let player = player()
        guard player.openAudioFile(url) else { XCTFail("An audio document must be accepted"); return }
        try await wait { !player.isLoading && player.current?.filename == "Chosen.WAV" }
        XCTAssertEqual(player.queue.tracks.count, 1)
        let track = try XCTUnwrap(player.current), access = try player.folderAccess(for: track)
        XCTAssertEqual(track.url(in: access.url).standardizedFileURL, url.standardizedFileURL)
        var stale = false
        let bookmarked = try URL(resolvingBookmarkData: access.bookmark(), options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(bookmarked.standardizedFileURL, url.standardizedFileURL, "Keep the file grant, never create a bookmark to its parent")
        XCTAssertEqual(player.currentDetails?.title, "Shared song"); XCTAssertEqual(player.currentDetails?.artist, "Shared artist")
        XCTAssertEqual(player.currentDetails?.album, "Shared album"); XCTAssertEqual(player.currentDetails?.tags[.genre], "Rock")
        XCTAssertNotNil(player.currentDetails?.artwork)
        XCTAssertEqual(player.currentDetails?.lyrics.lines.map(\.text), ["First", "Last"])
        XCTAssertEqual(player.currentDetails?.lyrics.lines.compactMap(\.time), [0.1, 1])
        XCTAssertEqual(player.currentDetails?.duration ?? 0, 3, accuracy: 0.01)
        try await wait { player.currentTime > 0.03 }
        XCTAssertTrue(player.library.state.sources.isEmpty); XCTAssertTrue(player.library.state.songs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("managed").path))
    }
    func testInvalidAndCorruptDocumentsPreserveExistingPlaybackAndLibrary() async throws {
        let original = try audio("library/Original.wav"), selected = try audio("outside/Chosen.wav")
        let player = player()
        await player.loadFolder(original.deletingLastPathComponent(), autoPlay: false)
        let previous = player.queue.tracks, sources = player.library.state.sources.map(\.id)
        XCTAssertFalse(player.openAudioFile(URL(string: "https://example.com/song.mp3")!))
        XCTAssertFalse(player.openAudioFile(root.appendingPathComponent("notes.txt")))
        XCTAssertFalse(player.openAudioFile(root.appendingPathComponent("missing.mp3")))
        XCTAssertFalse(player.openAudioFile(original.deletingLastPathComponent()))
        XCTAssertEqual(player.queue.tracks, previous)
        let corrupt = root.appendingPathComponent("corrupt.mp3")
        try Data("not audio".utf8).write(to: corrupt)
        XCTAssertTrue(player.openAudioFile(corrupt))
        try await wait { player.issue != nil && !player.isLoading }
        XCTAssertEqual(player.queue.tracks, previous); XCTAssertNil(player.openedAudioFileID)
        XCTAssertEqual(player.library.state.sources.map(\.id), sources)
        XCTAssertTrue(player.openAudioFile(selected))
        try await wait { !player.isLoading && player.current?.filename == selected.lastPathComponent }
        XCTAssertNil(player.issue); XCTAssertNotNil(player.openedAudioFileID)
        XCTAssertEqual(player.library.state.sources.map(\.id), sources)
        XCTAssertEqual(player.library.state.songs.count, 1)
    }
    func testRapidOpensKeepLastSelectionAndRepeatedFileKeepsIdentity() async throws {
        let first = try audio("one/Song.wav"), last = try audio("two/Song.wav")
        let player = player()
        XCTAssertTrue(player.openAudioFile(first)); XCTAssertTrue(player.openAudioFile(last))
        try await wait { !player.isLoading && player.current != nil }
        let track = try XCTUnwrap(player.current)
        XCTAssertEqual(try track.url(in: player.folderAccess(for: track).url).standardizedFileURL, last.standardizedFileURL)
        XCTAssertEqual(player.queue.tracks.count, 1)
        let event = try XCTUnwrap(player.openedAudioFileID)
        XCTAssertTrue(player.openAudioFile(last))
        try await wait { player.openedAudioFileID != event }
        XCTAssertEqual(player.current?.id, track.id)
    }
    func testFileBookmarkRestoresPausedWithoutImportOrParentFolderAccess() async throws {
        let chosen = try audio("outside/Chosen.wav"), sibling = try audio("outside/Sibling.wav")
        let original = player(); XCTAssertTrue(original.openAudioFile(chosen))
        try await wait { !original.isLoading && original.currentTime > 0.03 }
        original.seek(to: 1)
        try await wait { original.currentTime > 1.03 }
        original.pause(); original.stop()
        let data = try XCTUnwrap(defaults.data(forKey: "multiFolderQueue"))
        let snapshot = try JSONDecoder().decode(MultiFolderSnapshot.self, from: data)
        let track = try XCTUnwrap(snapshot.tracks.first), source = try XCTUnwrap(track.sourceID)
        let tampered = MultiFolderSnapshot(bookmarks: snapshot.bookmarks,
            tracks: [track, try XCTUnwrap(AudioTrack(relativePath: sibling.lastPathComponent, sourceID: source))],
            selectedID: track.id, position: snapshot.position, name: snapshot.name, primaryLibraryID: nil)
        let resolved = try await tampered.resolve()
        XCTAssertEqual(resolved.tracks, [track], "One file's bookmark cannot authorize a sibling")
        XCTAssertEqual(resolved.folders[source]?.documentURL?.standardizedFileURL, chosen.standardizedFileURL)
        let restored = player(); await restored.restoreFolder()
        XCTAssertEqual(restored.current?.id, track.id); XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.currentTime, snapshot.position, accuracy: 0.1)
        XCTAssertEqual(restored.currentDetails?.lyrics.lines.map(\.text), ["First", "Last"])
        XCTAssertTrue(restored.library.state.sources.isEmpty)
        restored.togglePlayback(); try await wait { restored.currentTime > snapshot.position + 0.03 }
    }
    func testColdOpenWinsOverSavedQueueAndSharedRestoration() async throws {
        let previous = try audio("library/Previous.wav"), chosen = try audio("outside/Chosen.wav")
        let original = player(); await original.loadFolder(previous.deletingLastPathComponent(), autoPlay: false); original.stop()
        let reopened = player(), services = AppServices(player: reopened)
        services.openAudioFile(chosen)
        await services.restore()
        try await wait { !reopened.isLoading && reopened.current?.filename == chosen.lastPathComponent }
        await services.restore()
        XCTAssertEqual(reopened.queue.tracks.count, 1)
        XCTAssertEqual(reopened.current?.filename, chosen.lastPathComponent)
        XCTAssertEqual(reopened.library.state.sources.count, 1, "The prior source remains; the opened file is not imported")
        XCTAssertEqual(reopened.library.state.songs.count, 1)
    }
    func testOpenDuringRestorationKeepsNewSelectionAndMixedQueueCanRestore() async throws {
        let previous = try audio("library/Previous.wav"), chosen = try audio("outside/Chosen.wav")
        let original = player(); await original.loadFolder(previous.deletingLastPathComponent(), autoPlay: false); original.stop()
        let reopened = player(), services = AppServices(player: reopened)
        let restoration = Task { await services.restore() }
        await Task.yield()
        services.openAudioFile(chosen)
        await restoration.value
        try await wait { !reopened.isLoading && reopened.current?.filename == chosen.lastPathComponent }
        XCTAssertNil(reopened.issue)
        await reopened.appendFolder(previous.deletingLastPathComponent())
        XCTAssertEqual(reopened.queue.tracks.count, 2)
        reopened.stop()
        let restored = player(); await restored.restoreFolder()
        XCTAssertEqual(restored.queue.tracks.count, 2)
        XCTAssertEqual(restored.current?.filename, chosen.lastPathComponent)
        XCTAssertEqual(restored.library.state.sources.count, 1)
        for track in restored.queue.tracks {
            let access = try restored.folderAccess(for: track)
            XCTAssertTrue(access.permits(track.url(in: access.url)))
        }
    }
    func testOpenedMP3RestoresEmbeddedSongAndAlbumReadingsWithoutImportOrGeneration() async throws {
        let url = root.appendingPathComponent("saved.mp3")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp3")), to: url)
        let native = try AudioFile(readingPropertiesAndMetadataFrom: url)
        native.metadata.title = "Saved song"; native.metadata.artist = "Saved artist"; native.metadata.albumTitle = "Saved album"
        native.metadata.lyrics = "Hello\nWorld"; try native.writeMetadata()
        let context = LyricsInterpretationContext(title: "Saved song", artist: "Saved artist", album: "Saved album")
        let document = LyricsDocument(text: "Hello\nWorld")
        let reading = try JSONDecoder().decode(LyricsInterpretation.self, from: Data(#"{"explanation":"Saved interpretation.","model":"gpt-6-astra","effort":"medium"}"#.utf8))
        let portable = PortableInterpretations(
            songs: ["es": .init(language: "es", title: context.title, artist: context.artist, album: context.album,
                                lyricsDigest: PortableInterpretations.lyricsDigest(document), interpretation: reading)],
            albums: ["es": .init(language: "es", title: context.album, artist: context.artist, trackCount: 12, missingLyrics: 2, interpretation: reading)])
        try ID3ExportTags.write(portable.tags(), to: url)
        let bytes = try Data(contentsOf: url)
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata-cache")))
        let meanings = LyricInterpretationStore(settings: settings) { _, _, _, mode in
            XCTAssertEqual(mode, .cachedOnly, "File playback must not generate another interpretation")
            throw MetadataLookupError.notCached
        }
        let albums = AlbumInterpretationStore(settings: settings, cache: MusicToolsCache(root: root.appendingPathComponent("album-cache"))) { _, _, _ in
            XCTFail("An embedded album reading must not be regenerated from this one song"); throw MetadataLookupError.notCached
        }
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("managed"),
                                        lyricInterpretations: meanings, albumInterpretations: albums, activateSession: {})
        players.append(player); XCTAssertTrue(player.openAudioFile(url))
        try await wait { !player.isLoading && player.current != nil }
        await meanings.restore(document, language: "es", context: context)
        XCTAssertEqual(meanings.results[meanings.key(document, language: "es", context: context)]?.explanation, reading.explanation)
        let album = try XCTUnwrap(player.currentAlbum, "Expose the album metadata without adding a library source")
        let result = try await albums.cachedResult(album, language: "es", character: false)
        XCTAssertEqual(result?.interpretation.explanation, reading.explanation)
        XCTAssertEqual(result?.trackCount, 12); XCTAssertEqual(result?.missingLyrics, 2)
        XCTAssertTrue(player.library.state.sources.isEmpty); XCTAssertTrue(player.library.state.songs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
