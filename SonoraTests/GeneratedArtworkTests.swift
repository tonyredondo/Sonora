import AVFAudio
import SFBAudioEngine
import SonoraCore
import SwiftUI
import UIKit
import XCTest
@testable import Sonora

@MainActor final class GeneratedArtworkTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: MetadataAssistantSettings!
    private var bindings: MusicToolsCache!
    private var images: MetadataLookupCache!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ArtworkTests.\(UUID())"; defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        for key in ["prepareQueueAudio", "prepareQueueCharacter", "prepareQueueMeaning", "prepareQueueTranslation"] { defaults.set(false, forKey: key) }
        settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: .init(directory: root.appendingPathComponent("metadata")))
        bindings = MusicToolsCache(root: root.appendingPathComponent("bindings")); images = MetadataLookupCache(directory: root.appendingPathComponent("images"))
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite); try FileManager.default.removeItem(at: root) }
    private var context: GeneratedArtworkInput { .init(title: "Quiet Horizon", artist: "Synthetic Artist", album: "First Light", albumDescription: "A contemplative album about beginnings.", genre: "Ambient", moods: ["relaxed"]) }
    private func png(_ color: UIColor = .cyan) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { renderer in color.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) }.pngData())
    }
    private func fingerprint(_ name: String) throws -> FileFingerprint {
        let file = root.appendingPathComponent(name); try Data(name.utf8).write(to: file); return try FileFingerprint(file)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func store(_ generate: @escaping GeneratedArtworkStore.Generator) -> GeneratedArtworkStore {
        GeneratedArtworkStore(settings: settings, bindings: bindings, images: images, requests: CodexRequestPool(), generate: generate)
    }
    func testPersistsOnceRestoresOfflineAndDisabledDoesNotGenerate() async throws {
        let fp = try fingerprint("one"), context = self.context, image = try png()
        var calls = 0
        let store = store { request in calls += 1; XCTAssertEqual(request, context); return image }
        store.select(owner: "one", fingerprint: fp)
        for _ in 0..<3 { store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context } }
        try await wait { store.statuses["one"] == .ready && store.image(owner: "one", fingerprint: fp) != nil }
        XCTAssertEqual(calls, 1)
        defaults.set(true, forKey: "metadata.offline")
        let reopened = self.store { _ in XCTFail("Offline restore must not generate"); throw GeneratedArtworkIssue.unavailable }
        reopened.select(owner: "one", fingerprint: fp)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: false) { XCTFail("Saved binding needs no context recollection"); return context }
        try await wait { reopened.image(owner: "one", fingerprint: fp) != nil }
        XCTAssertEqual(reopened.statuses["one"], .ready)
        reopened.enqueue(owner: "new", fingerprint: fp, enabled: false) { XCTFail("Disabled work must not collect"); return context }
        try await wait { reopened.statuses["new"] == .waiting }
    }
    func testLateResponseNeverReplacesAnotherSongAndRemainsCached() async throws {
        let first = try fingerprint("one"), second = try fingerprint("two"), image = try png(), context = self.context
        var release: CheckedContinuation<Data, Never>?
        let store = store { _ in await withCheckedContinuation { release = $0 } }
        store.select(owner: "one", fingerprint: first); store.enqueue(owner: "one", fingerprint: first, enabled: true) { context }
        try await wait { release != nil }
        store.select(owner: "two", fingerprint: second)
        release?.resume(returning: image)
        try await wait { store.statuses["one"] == .ready }
        XCTAssertNil(store.image(owner: "two", fingerprint: second))
        store.select(owner: "one", fingerprint: first)
        try await wait { store.image(owner: "one", fingerprint: first) != nil }
    }
    func testRealArtworkSkipsGenerationAndFailureIsRetryable() async throws {
        let fp = try fingerprint("one"), context = self.context
        var calls = 0
        let store = store { _ in calls += 1; throw GeneratedArtworkIssue.unavailable }
        store.enqueue(owner: "real", fingerprint: fp, enabled: true) { nil }
        try await wait { store.statuses["real"] == .ready }; XCTAssertEqual(calls, 0)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.automaticIssue != nil }; XCTAssertEqual(calls, 1)
        store.enqueue(owner: "two", fingerprint: fp, enabled: true) { context }
        try await wait { store.pendingCount == 0 }; XCTAssertEqual(calls, 1)
        store.retry(); store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { calls == 2 }
        try await wait { store.pendingCount == 0 }
    }
    func testEnablingArtworkAfterDisabledPreparationStartsTheSameSong() async throws {
        let fp = try fingerprint("one"), context = self.context, image = try png()
        var calls = 0
        let store = store { _ in calls += 1; return image }
        store.enqueue(owner: "one", fingerprint: fp, enabled: false) { context }
        try await wait { store.statuses["one"] == .waiting }
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { calls == 1 && store.statuses["one"] == .ready }
    }
    func testInvalidImageIsNeverCachedOrDisplayed() async throws {
        let fp = try fingerprint("one"), context = self.context
        let store = store { _ in Data("broken PNG".utf8) }
        store.select(owner: "one", fingerprint: fp); store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.automaticIssue != nil }
        XCTAssertNil(store.image(owner: "one", fingerprint: fp))
        let restored = try await store.restore(owner: "one", fingerprint: fp); XCTAssertFalse(restored)
    }
    func testCurrentFileChangeAndSharedCapacityKeepNewestImage() async throws {
        let first = try fingerprint("one"), second = try fingerprint("replacement"), image = try png(), context = self.context
        var started: [String] = [], releases: [CheckedContinuation<Data, Never>] = []
        let store = store { context in
            started.append(context.title)
            return await withCheckedContinuation { releases.append($0) }
        }
        for index in 0..<6 {
            store.enqueue(owner: "item\(index)", fingerprint: first, enabled: true) {
                .init(title: "Song \(index)", artist: "", album: "", albumDescription: "")
            }
        }
        try await wait { releases.count == 4 }; XCTAssertEqual(started.count, 4)
        let initial = releases; releases = []; initial.forEach { $0.resume(returning: image) }
        try await wait { releases.count == 2 }
        let rest = releases; releases = []; rest.forEach { $0.resume(returning: image) }
        try await wait { store.pendingCount == 0 }
        store.enqueue(owner: "changed", fingerprint: first, enabled: true) { context }
        try await wait { releases.count == 1 }
        store.select(owner: "changed", fingerprint: second)
        store.enqueue(owner: "changed", fingerprint: second, enabled: true) { context }
        releases.removeFirst().resume(returning: image)
        try await wait { store.image(owner: "changed", fingerprint: second) != nil }
        XCTAssertNil(store.image(owner: "changed", fingerprint: first))
        XCTAssertEqual(started.count, 7, "The replacement reuses the same completed semantic image")
    }
    func testPlayerUsesAlbumReadingAndTagsThenDisplaysCoverWithoutEditingAudio() async throws {
        let url = root.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "wav")), to: url)
        let native = try AudioFile(readingPropertiesAndMetadataFrom: url)
        native.metadata.removeAllAttachedPictures(); native.metadata.title = "Quiet Horizon"; native.metadata.artist = "Synthetic Artist"
        native.metadata.albumTitle = "First Light"; native.metadata.genre = "Ambient"; native.metadata.lyrics = "A new beginning."
        try native.writeMetadata()
        let before = try Data(contentsOf: url), image = try png(), explanation = "A contemplative album about beginnings."
        defaults.set(true, forKey: "prepareQueueMeaning")
        let result = try JSONDecoder().decode(LyricsInterpretation.self, from: JSONSerialization.data(withJSONObject: ["explanation": explanation, "model": "gpt-6-astra", "effort": "medium"]))
        let albums = AlbumInterpretationStore(settings: settings, cache: bindings, requests: CodexRequestPool()) { _, _, _ in result }
        let meanings = LyricInterpretationStore(settings: settings, requests: CodexRequestPool()) { _, _, _, _ in result }
        var received: [GeneratedArtworkInput] = []
        let artwork = store { value in received.append(value); return image }
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("managed"),
            lyricInterpretations: meanings, albumInterpretations: albums, generatedArtwork: artwork, activateSession: {})
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        try await wait { !received.isEmpty && player.currentDetails?.artwork != nil }
        let request = try XCTUnwrap(received.first)
        XCTAssertEqual(request.title, "Quiet Horizon"); XCTAssertEqual(request.albumDescription, explanation)
        XCTAssertEqual(request.genre, "Ambient"); XCTAssertEqual(request.artist, "Synthetic Artist")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let owner = GeneratedArtworkStore.owner(try XCTUnwrap(player.current), folder: try player.folderAccess(for: XCTUnwrap(player.current)))
        XCTAssertNotNil(artwork.image(owner: owner, fingerprint: try FileFingerprint(url)))

        // Render the same player view used by the full-screen presentation.
        let original = UserDefaults.standard.object(forKey: "nowPlayingPage")
        UserDefaults.standard.set(0, forKey: "nowPlayingPage")
        defer { if let original { UserDefaults.standard.set(original, forKey: "nowPlayingPage") } else { UserDefaults.standard.removeObject(forKey: "nowPlayingPage") } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NowPlayingView(player: player)); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(500))
        let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screen); attachment.name = "generated-artwork-player"; attachment.lifetime = .keepAlways; add(attachment)

        let real = try AudioFile(readingPropertiesAndMetadataFrom: url)
        real.metadata.attachPicture(AttachedPicture(imageData: try png(.red), type: .frontCover)); try real.writeMetadata()
        let withCover = try Data(contentsOf: url)
        await player.loadFolder(root, autoPlay: false)
        try await wait { player.currentDetails?.artwork != nil && artwork.pendingCount == 0 }
        XCTAssertEqual(received.count, 1, "A real cover must prevent another generation")
        XCTAssertEqual(try Data(contentsOf: url), withCover)
    }

    func testAppContainerRelocationRetainsArtworkOwner() throws {
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        for home in [old, new] { try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true) }
        let track = try XCTUnwrap(AudioTrack(relativePath: "song.wav"))
        let a = try ScopedFolder(old.appendingPathComponent("Documents")), b = try ScopedFolder(new.appendingPathComponent("Documents"))
        XCTAssertEqual(GeneratedArtworkStore.owner(track, folder: a, appHome: old), GeneratedArtworkStore.owner(track, folder: b, appHome: new))
        XCTAssertNotEqual(GeneratedArtworkStore.owner(track, folder: a, appHome: old), GeneratedArtworkStore.owner(track, folder: b, appHome: old))
    }

}
