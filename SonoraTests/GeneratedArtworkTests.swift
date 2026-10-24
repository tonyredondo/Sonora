import AVFAudio
import Observation
import SFBAudioEngine
import SonoraCore
import SwiftUI
import UIKit
import XCTest
@testable import Sonora

private actor ArtworkJobsFixture: MetadataLookupTransport {
    let image: Data
    let id = String(repeating: "b", count: 64)
    var state = "running"
    var failure: String?
    var disconnected = false
    var loseAcknowledgement = false
    var delayAcknowledgement = false
    var holdDownloads = false
    private(set) var submissions = 0
    private(set) var attempts = 0
    private(set) var inputs: [GeneratedArtworkInput] = []
    private(set) var paths: [URL] = []
    private var generated: Set<String> = []
    var generations: Int { generated.count }
    init(image: Data) { self.image = image }
    func complete() { state = "completed" }
    func fail(_ code: String) { state = "failed"; failure = code }
    func disconnect(_ value: Bool) { disconnected = value }
    func loseNextAcknowledgement() { loseAcknowledgement = true }
    func delayNextAcknowledgement() { delayAcknowledgement = true }
    func holdDownloads(_ value: Bool) { holdDownloads = value }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        if let url = request.url { paths.append(url) }
        if disconnected { throw URLError(.networkConnectionLost) }
        if request.httpMethod == "POST" {
            submissions += 1
            let input = try JSONDecoder().decode(GeneratedArtworkInput.self, from: request.httpBody ?? Data())
            inputs.append(input)
            let retryFailed = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.contains(URLQueryItem(name: "retry_failed", value: "true")) == true
            if generated.insert(input.cacheIdentity).inserted || (state == "failed" && retryFailed) { attempts += 1 }
            if state == "failed", retryFailed { state = "running"; failure = nil }
            if loseAcknowledgement { loseAcknowledgement = false; throw URLError(.networkConnectionLost) }
            if delayAcknowledgement { delayAcknowledgement = false; try await Task.sleep(for: .seconds(60)) }
        }
        if request.url?.path.hasSuffix("/image") == true {
            while holdDownloads { try await Task.sleep(for: .milliseconds(10)) }
            return .init(data: image, status: 200, contentType: "image/png")
        }
        var body = ["id": id, "state": state]
        if let failure { body["error"] = failure }
        return .init(data: try JSONSerialization.data(withJSONObject: body), status: request.httpMethod == "POST" ? 202 : 200, contentType: "application/json")
    }
}

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
    private func jobStore(_ http: ArtworkJobsFixture) -> GeneratedArtworkStore {
        let settings = self.settings!
        return GeneratedArtworkStore(settings: settings, bindings: bindings, images: images, requests: CodexRequestPool(),
            clientFactory: { try GeneratedArtworkClient(connection: .init(endpoint: settings.endpoint, token: "fixture"), transport: http) }, pollInterval: .milliseconds(10))
    }
    func testBackgroundAndRelaunchRecoverTheSavedJobWithoutPreparingOrGeneratingAgain() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let original = jobStore(http)
        original.select(owner: "one", fingerprint: fp)
        original.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { original.currentStatus == .generating }
        original.setActive(false)
        try await wait { original.currentStatus == .paused }
        await http.complete()
        let reopened = jobStore(http)
        reopened.select(owner: "one", fingerprint: fp)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("A saved job must resume before collecting context"); return nil }
        try await wait { reopened.currentStatus == .ready }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1)
        XCTAssertNotNil(reopened.image(owner: "one", fingerprint: fp))
        original.setActive(true)
        try await wait { original.pendingCount == 0 }
    }
    func testConnectionFailureRetainsJobForAnExplicitRetry() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let store = jobStore(http)
        store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.currentStatus == .generating }
        await http.disconnect(true)
        try await wait { store.pendingCount == 0 }
        guard case .waitingForConnection = store.currentStatus else { return XCTFail("Connection failures must not look like generation") }
        await http.disconnect(false); await http.complete()
        store.retry()
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("Retry must retain the saved job"); return nil }
        try await wait { store.currentStatus == .ready }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1)
    }
    func testLostAcknowledgementKeepsOriginalInputAndResubmitsIdempotently() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        await http.loseNextAcknowledgement()
        let first = jobStore(http)
        first.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { first.pendingCount == 0 }
        await http.complete()
        let reopened = jobStore(http); reopened.select(owner: "one", fingerprint: fp)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("The original input must survive an unacknowledged submission"); return nil }
        try await wait { reopened.currentStatus == .ready }
        let submissions = await http.submissions, generations = await http.generations
        XCTAssertEqual(submissions, 2); XCTAssertEqual(generations, 1)
    }
    func testLostAcknowledgementDoesNotRetryAFailureThatFinishesInBackground() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        await http.loseNextAcknowledgement()
        let original = jobStore(http)
        original.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { original.pendingCount == 0 }
        await http.fail("codex_limit")
        let reopened = jobStore(http); reopened.select(owner: "one", fingerprint: fp)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("Recover the original submission"); return nil }
        try await wait { reopened.pendingCount == 0 }
        guard case .failed = reopened.currentStatus else { return XCTFail("Recovery must display the terminal failure") }
        let attempts = await http.attempts; XCTAssertEqual(attempts, 1)
        reopened.retry()
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { reopened.currentStatus == .generating }
        await http.complete(); try await wait { reopened.currentStatus == .ready }
        let retried = await http.attempts; XCTAssertEqual(retried, 2)
    }
    func testBackgroundCancelsOnlyTheRequestAndRecoversTheAcceptedJob() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        await http.delayNextAcknowledgement()
        let store = jobStore(http); store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        for _ in 0..<500 {
            if await http.submissions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.setActive(false)
        try await wait { store.currentStatus == .paused }
        await http.complete(); store.setActive(true)
        try await wait { store.currentStatus == .ready }
        let generations = await http.generations; XCTAssertEqual(generations, 1)
    }
    func testChangingServerWhilePausedDoesNotResumeAgainstTheOldConnection() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let store = jobStore(http); store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.currentStatus == .generating }
        store.setActive(false); try await wait { store.currentStatus == .paused }
        try settings.save(endpoint: "http://127.0.0.1:19", token: "")
        store.retry()
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        await http.complete(); store.setActive(true)
        try await wait { store.currentStatus == .ready }
        let posts = await http.paths.filter { $0.path == "/v1/artwork/jobs" }
        XCTAssertEqual(posts.map(\.port), [9, 19])
        XCTAssertNil(store.automaticIssue)
    }
    func testRelaunchRetainsTerminalFailureUntilAnExplicitRetry() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let original = jobStore(http)
        original.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { original.statuses["one"] == .generating }
        await http.fail("codex_limit")
        try await wait { original.pendingCount == 0 }
        let reopened = jobStore(http); reopened.select(owner: "one", fingerprint: fp)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("A failed job must also remain recoverable"); return nil }
        try await wait { reopened.pendingCount == 0 }
        guard case .failed = reopened.currentStatus else { return XCTFail("The saved failure must be displayed") }
        let before = await http.attempts; XCTAssertEqual(before, 1)
        reopened.retry(failed: false)
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        let automatic = await http.attempts; XCTAssertEqual(automatic, 1)
        reopened.retry()
        reopened.enqueue(owner: "one", fingerprint: fp, enabled: true) { XCTFail("An explicit retry reuses its saved input"); return nil }
        try await wait { reopened.currentStatus == .generating }
        await http.complete()
        try await wait { reopened.currentStatus == .ready }
        let after = await http.attempts; XCTAssertEqual(after, 2)
    }
    func testFirstJobNotifiesObserversAndOfflinePreparationStopsSpinning() async throws {
        let fp = try fingerprint("one"), context = self.context
        let store = store { _ in XCTFail("Going offline during preparation must not start generation"); throw GeneratedArtworkIssue.unavailable }
        store.select(owner: "one", fingerprint: fp)
        let changed = expectation(description: "The player observes the first preparation")
        withObservationTracking { _ = store.currentStatus } onChange: { changed.fulfill() }
        var prepared: CheckedContinuation<GeneratedArtworkInput?, Never>?
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) {
            await withCheckedContinuation { prepared = $0 }
        }
        await fulfillment(of: [changed], timeout: 1)
        try await wait { prepared != nil }
        XCTAssertEqual(store.currentStatus, .preparing)
        settings.offline = true
        prepared?.resume(returning: context)
        try await wait { store.pendingCount == 0 }
        XCTAssertEqual(store.currentStatus, .waiting)
        XCTAssertNil(store.currentIssue)
    }
    func testPersistsOnceRestoresOfflineAndDisabledDoesNotGenerate() async throws {
        let fp = try fingerprint("one"), context = self.context, image = try png()
        var calls = 0
        let store = store { request in calls += 1; XCTAssertEqual(request, context); return image }
        store.select(owner: "one", fingerprint: fp)
        for _ in 0..<3 { store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context } }
        try await wait { store.statuses["one"] == .ready && store.image(owner: "one", fingerprint: fp) != nil }
        XCTAssertEqual(calls, 1)
        settings.offline = true
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
        XCTAssertEqual(store.currentStatus, .generating)
        store.select(owner: "two", fingerprint: second)
        XCTAssertNil(store.currentStatus, "Another song's generation must not appear on the selected song")
        release?.resume(returning: image)
        try await wait { store.statuses["one"] == .ready }
        XCTAssertNil(store.image(owner: "two", fingerprint: second))
        store.select(owner: "one", fingerprint: first)
        try await wait { store.image(owner: "one", fingerprint: first) != nil }
        XCTAssertEqual(store.currentStatus, .ready)
    }
    func testRealArtworkSkipsGenerationAndFailureIsRetryable() async throws {
        let fp = try fingerprint("one"), context = self.context
        var calls = 0
        let store = store { _ in calls += 1; throw GeneratedArtworkIssue.unavailable }
        store.enqueue(owner: "real", fingerprint: fp, enabled: true) { nil }
        try await wait { store.statuses["real"] == .ready }; XCTAssertEqual(calls, 0)
        store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.automaticIssue != nil }; XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.currentStatus, .failed(GeneratedArtworkIssue.unavailable.localizedDescription))
        store.retry(failed: false)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        XCTAssertEqual(calls, 1, "Returning to the app must not automatically repeat a terminal generation failure")
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
        try await wait { store.statuses["item4"] == .queued }
        store.select(owner: "item4", fingerprint: first)
        XCTAssertEqual(store.currentStatus, .queued)
        store.retry()
        XCTAssertEqual(store.currentStatus, .queued, "Retry must retain active jobs waiting for a shared slot")
        let initial = releases; releases = []; initial.forEach { $0.resume(returning: image) }
        try await wait { releases.count == 2 }
        let rest = releases; releases = []; rest.forEach { $0.resume(returning: image) }
        try await wait { store.pendingCount == 0 }
        store.enqueue(owner: "changed", fingerprint: first, enabled: true) { context }
        try await wait { releases.count == 1 }
        store.select(owner: "changed", fingerprint: second)
        XCTAssertNil(store.currentStatus, "A replaced file must not inherit the old fingerprint's progress")
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
        let http = ArtworkJobsFixture(image: image)
        await http.delayNextAcknowledgement()
        let artwork = jobStore(http)
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("managed"),
            lyricInterpretations: meanings, albumInterpretations: albums, generatedArtwork: artwork, activateSession: {})
        defer { player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(root, autoPlay: false)
        for _ in 0..<500 {
            if await http.submissions == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(artwork.currentStatus, .connecting)
        XCTAssertNil(player.currentDetails?.artwork)
        let received = await http.inputs
        let request = try XCTUnwrap(received.first)
        XCTAssertEqual(request.title, "Quiet Horizon"); XCTAssertEqual(request.albumDescription, explanation)
        XCTAssertEqual(request.genre, "Ambient"); XCTAssertEqual(request.artist, "Synthetic Artist")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let owner = GeneratedArtworkStore.owner(try XCTUnwrap(player.current), folder: try player.folderAccess(for: XCTUnwrap(player.current)))

        // Render the same player view used by the full-screen presentation.
        let original = UserDefaults.standard.object(forKey: "nowPlayingPage")
        UserDefaults.standard.set(0, forKey: "nowPlayingPage")
        defer { if let original { UserDefaults.standard.set(original, forKey: "nowPlayingPage") } else { UserDefaults.standard.removeObject(forKey: "nowPlayingPage") } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: NowPlayingView(player: player)); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(500))
        func capture(_ name: String) {
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: screen); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        capture("generated-artwork-player-connecting")
        artwork.setActive(false)
        try await wait { artwork.currentStatus == .paused }
        try await Task.sleep(for: .milliseconds(300))
        capture("generated-artwork-player-paused")
        artwork.setActive(true)
        try await wait { artwork.currentStatus == .generating }
        try await Task.sleep(for: .milliseconds(300))
        capture("generated-artwork-player-creating")
        await http.disconnect(true)
        try await wait { artwork.pendingCount == 0 }
        try await Task.sleep(for: .milliseconds(300))
        capture("generated-artwork-player-connection")
        await http.disconnect(false); await http.holdDownloads(true); await http.complete()
        player.retryQueuePreparation()
        try await wait { artwork.currentStatus == .downloading }
        try await Task.sleep(for: .milliseconds(300))
        capture("generated-artwork-player-downloading")
        await http.holdDownloads(false)
        try await wait { player.currentDetails?.artwork != nil }
        XCTAssertEqual(artwork.currentStatus, .ready)
        XCTAssertNotNil(artwork.image(owner: owner, fingerprint: try FileFingerprint(url)))
        try await Task.sleep(for: .milliseconds(500))
        capture("generated-artwork-player-ready")

        let real = try AudioFile(readingPropertiesAndMetadataFrom: url)
        real.metadata.attachPicture(AttachedPicture(imageData: try png(.red), type: .frontCover)); try real.writeMetadata()
        let withCover = try Data(contentsOf: url)
        await player.loadFolder(root, autoPlay: false)
        try await wait { player.currentDetails?.artwork != nil && artwork.pendingCount == 0 }
        let submissions = await http.submissions
        XCTAssertEqual(submissions, 2, "Only the lost acknowledgement may repeat submission")
        let generations = await http.generations
        XCTAssertEqual(generations, 1, "Background, reconnect and real covers must not repeat generation")
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
