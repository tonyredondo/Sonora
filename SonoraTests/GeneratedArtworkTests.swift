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
            clientFactory: { try GeneratedArtworkClient(connection: .init(endpoint: settings.endpoint, token: "fixture"), transport: http) }, pollInterval: .milliseconds(10), connectionRetryDelay: .milliseconds(20))
    }
    func testClearingSavedInformationIncludesGeneratedArtwork() async throws {
        let fp = try fingerprint("one"), context = self.context, data = try png()
        let artwork = store { _ in data }
        artwork.select(owner: "one", fingerprint: fp)
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { artwork.currentStatus == .ready && artwork.pendingCount == 0 }
        try await settings.cache.store(Data("cached query".utf8), key: "lookup", status: 200)
        try await bindings.write(["marker": "keep"], key: "personal", personal: true)
        try await bindings.write(["meaning": "keep"], key: "meaning")
        let sentinel = root.appendingPathComponent("images/unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        let player = PlaybackController(defaults: defaults, generatedArtwork: artwork, activateSession: {})
        defer { player.stop() }
        let services = AppServices(player: player)
        let before = try await services.lookupCacheSize(settings: settings)
        XCTAssertGreaterThan(before, 0)
        try await captureCacheSettings(services, name: "artwork-cache-settings-before")
        // The same composed action used by the phone's clear-cache control.
        try await services.clearLookupCaches(settings: settings)
        let remaining = try await images.size()
        XCTAssertEqual(remaining, 0, "Clearing information and covers must include generated covers")
        XCTAssertNil(artwork.image(owner: "one", fingerprint: fp), "The visible image must also be invalidated")
        let combined = try await services.lookupCacheSize(settings: settings)
        XCTAssertEqual(combined, 0)
        try await captureCacheSettings(services, name: "artwork-cache-settings-after")
        let annotation = try await bindings.read([String: String].self, key: "personal", personal: true)
        let meaning = try await bindings.read([String: String].self, key: "meaning")
        XCTAssertEqual(annotation, ["marker": "keep"]); XCTAssertEqual(meaning, ["meaning": "keep"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("one")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(settings.endpoint, "http://127.0.0.1:9")
        let reopened = store { _ in data }
        let restored = try await reopened.restore(owner: "one", fingerprint: fp)
        XCTAssertFalse(restored, "Relaunch cannot restore a deleted image from its old binding")
    }
    private func captureCacheSettings(_ services: AppServices, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: NavigationStack { MetadataConnectionView(settings: settings, services: services) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        func scrollToCache(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            }
            view.subviews.forEach(scrollToCache)
        }
        for _ in 0..<3 {
            scrollToCache(window)
            try await Task.sleep(for: .milliseconds(150))
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testClearingIgnoresLateArtworkAndDoesNotRemoveTheReplacementJob() async throws {
        let fp = try fingerprint("one"), context = self.context, data = try png()
        var releases: [CheckedContinuation<Data, Never>] = []
        var returned = 0
        let artwork = store { _ in
            let value = await withCheckedContinuation { releases.append($0) }
            returned += 1
            return value
        }
        artwork.select(owner: "one", fingerprint: fp)
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { releases.count == 1 }
        try await artwork.clearCache()
        XCTAssertNil(artwork.image(owner: "one", fingerprint: fp))
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { releases.count == 2 }
        releases[0].resume(returning: data)
        try await wait { returned == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(artwork.pendingCount, 1)
        XCTAssertEqual(artwork.currentStatus, .generating)
        let stale = try await images.size(); XCTAssertEqual(stale, 0)
        releases[1].resume(returning: data)
        try await wait { artwork.currentStatus == .ready && artwork.pendingCount == 0 }
        let fresh = try await images.size(); XCTAssertGreaterThan(fresh, 0)
    }
    func testClearingWhileBackgroundedDiscardsWaitersWithoutHanging() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let artwork = jobStore(http); artwork.select(owner: "one", fingerprint: fp)
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { artwork.currentStatus == .generating }
        artwork.setActive(false); try await wait { artwork.currentStatus == .paused }
        try await artwork.clearCache()
        artwork.setActive(true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(artwork.currentStatus); XCTAssertEqual(artwork.pendingCount, 0)
        let size = try await images.size(); XCTAssertEqual(size, 0)
        await http.complete()
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { artwork.currentStatus == .ready }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1, "An existing server job can be downloaded again without paying for another generation")
    }
    func testCacheClearFailureIsReportedAndARetryCanSucceed() async throws {
        let blocked = root.appendingPathComponent("blocked-cache")
        try Data("not a directory".utf8).write(to: blocked)
        let imageCache = MetadataLookupCache(directory: blocked)
        let artwork = GeneratedArtworkStore(settings: settings, bindings: bindings, images: imageCache)
        let player = PlaybackController(defaults: defaults, generatedArtwork: artwork, activateSession: {})
        defer { player.stop() }
        let services = AppServices(player: player)
        try await settings.cache.store(Data("preserve until successful".utf8), key: "lookup", status: 200)
        do { try await services.clearLookupCaches(settings: settings); XCTFail("A failed image-cache clear must not report success") }
        catch { }
        let retained = try await settings.cache.read(key: "lookup"); XCTAssertNotNil(retained)
        try FileManager.default.removeItem(at: blocked)
        try await imageCache.store(try png(), key: "image", status: 200)
        try await services.clearLookupCaches(settings: settings)
        let size = try await services.lookupCacheSize(settings: settings); XCTAssertEqual(size, 0)
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
    func testConnectionFailureRecoversAutomaticallyWithoutResubmittingTheJob() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let store = jobStore(http)
        store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.currentStatus == .generating }
        await http.disconnect(true)
        try await wait { if case .waitingForConnection = store.currentStatus { true } else { false } }
        guard case .waitingForConnection = store.currentStatus else { return XCTFail("Connection failures must not look like generation") }
        XCTAssertEqual(store.pendingCount, 1, "A connection loss must retain an automatic recovery task")
        await http.disconnect(false); await http.complete()
        try await wait { store.currentStatus == .ready }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1)
    }
    func testOneFailedCoverDoesNotPauseOtherSongs() async throws {
        let fp = try fingerprint("one"), context = self.context, data = try png()
        let artwork = store { input in
            if input.title == context.title { throw GeneratedArtworkIssue.service("codex_unavailable") }
            return data
        }
        artwork.enqueue(owner: "failed", fingerprint: fp, enabled: true) { context }
        try await wait { artwork.pendingCount == 0 }
        artwork.select(owner: "next", fingerprint: fp)
        artwork.enqueue(owner: "next", fingerprint: fp, enabled: true) { .init(title: "Next", artist: "Artist", album: "Album", albumDescription: "") }
        try await wait { artwork.currentStatus == .ready }
        XCTAssertNil(artwork.automaticIssue, "A failed song must not become a global queue pause")
        guard case .failed = artwork.statuses["failed"] else { return XCTFail("Keep the original song's failure visible") }
    }
    func testClearingWhileReconnectingCancelsAutomaticRecovery() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        await http.disconnect(true)
        let artwork = jobStore(http); artwork.select(owner: "one", fingerprint: fp)
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { if case .waitingForConnection = artwork.currentStatus { true } else { false } }
        try await artwork.clearCache()
        await http.disconnect(false); await http.complete()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(artwork.pendingCount, 0); XCTAssertNil(artwork.currentStatus)
        let remaining = try await images.size(); XCTAssertEqual(remaining, 0)
        let accepted = await http.submissions; XCTAssertEqual(accepted, 0)
    }
    func testReconnectionWaitsForForegroundThenRecoversAutomatically() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        let artwork = jobStore(http); artwork.select(owner: "one", fingerprint: fp)
        artwork.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { artwork.currentStatus == .generating }
        await http.disconnect(true)
        try await wait { if case .waitingForConnection = artwork.currentStatus { true } else { false } }
        artwork.setActive(false)
        try await wait { artwork.currentStatus == .paused }
        await http.disconnect(false); await http.complete()
        artwork.setActive(true)
        try await wait { artwork.currentStatus == .ready }
        let accepted = await http.submissions; XCTAssertEqual(accepted, 1)
    }
    func testLostAcknowledgementKeepsOriginalInputAndResubmitsIdempotently() async throws {
        let fp = try fingerprint("one"), context = self.context, http = ArtworkJobsFixture(image: try png())
        await http.loseNextAcknowledgement()
        let first = jobStore(http)
        first.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { if case .waitingForConnection = first.statuses["one"] { true } else { false } }
        // End this instance's consumers, retaining the durable unacknowledged job.
        try await first.clearCache()
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
        try await wait { if case .waitingForConnection = original.statuses["one"] { true } else { false } }
        try await original.clearCache()
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
        let store = store { _ in calls += 1; throw GeneratedArtworkIssue.serverUpdateRequired }
        store.enqueue(owner: "real", fingerprint: fp, enabled: true) { nil }
        try await wait { store.statuses["real"] == .ready }; XCTAssertEqual(calls, 0)
        store.select(owner: "one", fingerprint: fp)
        store.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { store.automaticIssue != nil }; XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.currentStatus, .failed(GeneratedArtworkIssue.serverUpdateRequired.localizedDescription))
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
        try await wait { store.pendingCount == 0 }
        guard case .failed = store.currentStatus else { return XCTFail("Invalid artwork must report a failure") }
        XCTAssertNil(store.automaticIssue, "An invalid image must not pause unrelated songs")
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
        try await wait { if case .waitingForConnection = artwork.currentStatus { true } else { false } }
        XCTAssertEqual(artwork.pendingCount, 1)
        try await Task.sleep(for: .milliseconds(300))
        capture("generated-artwork-player-connection")
        await http.disconnect(false); await http.holdDownloads(true); await http.complete()
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
    func testPlaylistRowsRestoreGeneratedCoversAndUpdateWithoutChangingPlaybackArtwork() async throws {
        let names = ["One", "Two", "Original", "Later"]
        let colors: [String: UIColor] = ["One": .cyan, "Two": .magenta, "Original": .blue, "Later": .green]
        let data = try colors.mapValues { try png($0) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "flac"))
        for name in names {
            let url = root.appendingPathComponent(name + ".flac")
            try FileManager.default.copyItem(at: fixture, to: url)
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            file.metadata.removeAllAttachedPictures(); file.metadata.title = name
            file.metadata.artist = "Sonora Tests"; file.metadata.albumTitle = "Generated covers QA"
            if name == "Original" { file.metadata.attachPicture(AttachedPicture(imageData: try png(.red), type: .frontCover)) }
            try file.writeMetadata()
        }
        let originalFiles = try names.map { try Data(contentsOf: root.appendingPathComponent($0 + ".flac")) }
        var release: CheckedContinuation<Data, Never>?, calls = 0
        let artwork = store { input in
            calls += 1
            if input.title == "Later" { return await withCheckedContinuation { release = $0 } }
            return data[input.title]!
        }
        defer { release?.resume(returning: data["Later"]!) }
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("managed"), generatedArtwork: artwork, activateSession: {})
        defer { player.stop(); player.library.cancelIndexing() }
        let folder = try ScopedFolder(root)
        let source = try player.library.register(folder, tracks: names.map { AudioTrack(relativePath: $0 + ".flac")! })
        await player.library.waitForIndexing()
        let ids = names.map { source + "\0" + $0 + ".flac" }
        let playlist = try XCTUnwrap(player.library.createPlaylist("Portadas generadas QA"))
        player.library.add(ids, to: playlist)
        for (index, id) in ids.enumerated() {
            let track = try XCTUnwrap(player.library.state.songs[id]?.audioTrack)
            let fp = try FileFingerprint(track.url(in: folder.url)), name = names[index]
            let owner = GeneratedArtworkStore.owner(track, folder: folder)
            if index == 0 { artwork.select(owner: owner, fingerprint: fp) }
            artwork.enqueue(owner: owner, fingerprint: fp, enabled: true) {
                .init(title: name, artist: "Sonora Tests", album: "Generated covers QA", albumDescription: "")
            }
        }
        try await wait { release != nil && artwork.pendingCount == 1 }
        let selectedTrack = try XCTUnwrap(player.library.state.songs[ids[0]]?.audioTrack)
        let selectedOwner = GeneratedArtworkStore.owner(selectedTrack, folder: folder)
        let selectedFingerprint = try FileFingerprint(selectedTrack.url(in: folder.url))
        let selectedImage = try XCTUnwrap(artwork.image(owner: selectedOwner, fingerprint: selectedFingerprint))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            CollectionSongList(player: player, title: "Portadas generadas QA", ids: ids, playlistID: playlist)
        }.tint(.orange))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        func capture() -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        }
        var screen = capture()
        for _ in 0..<20 {
            if coloredPixels(screen, color: .cyan) > 200 && coloredPixels(screen, color: .magenta) > 200 { break }
            try await Task.sleep(for: .milliseconds(100)); screen = capture()
        }
        XCTAssertGreaterThan(coloredPixels(screen, color: .cyan), 200, "The first generated cover must appear in its playlist row")
        XCTAssertGreaterThan(coloredPixels(screen, color: .magenta), 200, "Rows must restore covers other than the selected player's cover")
        XCTAssertGreaterThan(coloredPixels(screen, color: .red), 200, "Original artwork has priority over a generated cover")
        XCTAssertEqual(coloredPixels(screen, color: .blue), 0)
        XCTAssertEqual(coloredPixels(screen, color: .green), 0)
        let before = XCTAttachment(image: screen); before.name = "playlist-generated-covers-cached"; before.lifetime = .keepAlways; add(before)
        release?.resume(returning: data["Later"]!); release = nil
        try await wait { artwork.pendingCount == 0 }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100)); screen = capture()
            if coloredPixels(screen, color: .green) > 200 { break }
        }
        XCTAssertGreaterThan(coloredPixels(screen, color: .green), 200, "A completed cover must refresh the visible list without reopening it")
        XCTAssertEqual(calls, 4, "Displaying a playlist must never generate another image")
        XCTAssertTrue(artwork.image(owner: selectedOwner, fingerprint: selectedFingerprint) === selectedImage, "Reading list covers must not change the player's selected image")
        let completed = XCTAttachment(image: screen); completed.name = "playlist-generated-covers-completed"; completed.lifetime = .keepAlways; add(completed)
        try await artwork.clearCache()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100)); screen = capture()
            if coloredPixels(screen, color: .cyan) == 0 && coloredPixels(screen, color: .green) == 0 { break }
        }
        XCTAssertEqual(coloredPixels(screen, color: .cyan), 0); XCTAssertEqual(coloredPixels(screen, color: .magenta), 0)
        XCTAssertEqual(coloredPixels(screen, color: .green), 0)
        XCTAssertGreaterThan(coloredPixels(screen, color: .red), 200, "Clearing generated covers preserves original artwork")
        for (index, name) in names.enumerated() { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name + ".flac")), originalFiles[index]) }
    }
    func testCachedThumbnailRestoresOfflineAtListSizeAndRejectsChangedFiles() async throws {
        let fp = try fingerprint("one"), context = self.context
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format).image { renderer in
            UIColor.cyan.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }.pngData())
        let original = store { _ in large }
        original.enqueue(owner: "one", fingerprint: fp, enabled: true) { context }
        try await wait { original.pendingCount == 0 }
        XCTAssertEqual(original.statuses["one"], .ready)
        settings.offline = true
        let reopened = store { _ in XCTFail("A cached row must not generate images"); return large }
        let thumbnail = try await reopened.cachedThumbnail(owner: "one", fingerprint: fp)
        let image = try XCTUnwrap(thumbnail?.cgImage)
        XCTAssertLessThanOrEqual(image.width, 160); XCTAssertLessThanOrEqual(image.height, 160)
        XCTAssertNil(reopened.currentStatus); XCTAssertEqual(reopened.pendingCount, 0)
        try Data("replacement audio".utf8).write(to: root.appendingPathComponent("one"))
        let replaced = try FileFingerprint(root.appendingPathComponent("one"))
        let stale = try await reopened.cachedThumbnail(owner: "one", fingerprint: replaced)
        XCTAssertNil(stale, "A replaced audio file must not inherit an old generated cover")
    }
    private func coloredPixels(_ image: UIImage, color: UIColor) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let target = [Int(red * 255), Int(green * 255), Int(blue * 255)]
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, pixel in
            if (0..<3).allSatisfy({ abs(Int(bytes[pixel + $0]) - target[$0]) < 20 }) { count += 1 }
        }
    }

}
