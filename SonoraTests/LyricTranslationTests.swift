import Foundation
import SonoraCore
import XCTest
@testable import Sonora

final class LyricTranslationTests: XCTestCase {
    private let lyric = LyricsDocument(text: "[00:01]When the rain stops\n[00:03]we will go outside.\n[00:06]\n[00:07]When the rain stops\n[00:09]we will go outside.")

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    @MainActor func testAutomaticQueueWaitsOfflinePausesOnFailureAndResumesInPlaybackOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TranslationQueue.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite),
                                                 cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
        settings.offline = true
        var calls: [String] = [], fail = true
        var held: CheckedContinuation<Void, Never>?
        let store = LyricTranslationStore(cache: MusicToolsCache(root: root), settings: settings) { doc, _, _, _ in
            if settings.effectiveOffline { throw MetadataLookupError.notCached }
            calls.append(doc.lines[0].text)
            if fail { throw URLError(.cannotConnectToHost) }
            if doc.lines[0].text == "A" { await withCheckedContinuation { held = $0 } }
            return try LyricTranslation(lines: [0: "Traducción " + doc.lines[0].text], document: doc)
        }
        let a = LyricsDocument(text: "A"), b = LyricsDocument(text: "B"), c = LyricsDocument(text: "C")
        store.setAutomaticQueue(["a", "b", "c"], source: "en", target: "es")
        await store.enqueue(a, source: "en", target: "es", owner: "a")
        await store.enqueue(b, source: "en", target: "es", owner: "b")
        await store.enqueue(c, source: "en", target: "es", owner: "c")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.pendingCount, 3)
        do { _ = try await store.load(a, source: "en", target: "es"); XCTFail("No uncached result is available offline") }
        catch MetadataLookupError.notCached { }
        XCTAssertEqual(store.pendingCount, 3, "An offline manual attempt must preserve the automatic job for reconnection")
        XCTAssertTrue(calls.isEmpty)
        settings.offline = false
        try await wait { calls.count == 1 && store.automaticIssue != nil }
        XCTAssertEqual(calls, ["A"], "One failed server request pauses the entire automatic translation queue")
        await store.enqueue(a, source: "en", target: "es", owner: "a")
        XCTAssertEqual(calls.count, 1)
        fail = false; store.retryAutomatic()
        try await wait { held != nil && calls.count == 4 }
        store.setAutomaticQueue(["c", "a"], source: "en", target: "es")
        held?.resume(); held = nil
        try await wait { store.results.count == 3 }
        XCTAssertEqual(calls, ["A", "A", "B", "C"])
        XCTAssertEqual(store.statuses[LyricUnderstanding.translationKey(b, source: "en", target: "es")], .ready, "Already started work is retained after removal")
        settings.offline = true
        let reopened = LyricTranslationStore(cache: MusicToolsCache(root: root), settings: settings) { _, _, _, _ in
            XCTFail("Offline results must come from disk"); throw URLError(.unknown)
        }
        let saved = try await reopened.load(c, source: "en", target: "es")
        XCTAssertEqual(saved.lines[0], "Traducción C")
    }

    @MainActor func testRefreshDuringActiveAutomaticRequestUsesOneFollowingFreshRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = LyricsDocument(text: "[00:01]A tree grows.")
        var modes: [Bool] = [], held: CheckedContinuation<LyricTranslation, Never>?
        let store = LyricTranslationStore(cache: MusicToolsCache(root: root)) { _, _, _, refresh in
            modes.append(refresh)
            return await withCheckedContinuation { held = $0 }
        }
        let normal = Task { try await store.load(document, source: "en", target: "es") }
        try await wait { held != nil }
        let refresh = Task { try await store.load(document, source: "en", target: "es", refresh: true) }
        let second = Task { try await store.load(document, source: "en", target: "es", refresh: true) }
        await Task.yield()
        let old = try LyricTranslation(lines: [0: "Un árbol crece."], document: document)
        held?.resume(returning: old); held = nil
        let original = try await normal.value
        XCTAssertEqual(original, old)
        try await wait { modes.count == 2 && held != nil }
        XCTAssertEqual(modes, [false, true])
        let updated = try LyricTranslation(lines: [0: "Crece un árbol."], document: document)
        held?.resume(returning: updated); held = nil
        let firstValue = try await refresh.value, secondValue = try await second.value
        XCTAssertEqual(firstValue, updated); XCTAssertEqual(secondValue, updated)
        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(document.lines[0].time, 1)
    }

    @MainActor func testGroupedProviderResultIsRejectedAndCannotPoisonTheNewCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root)
        let doc = LyricsDocument(text: "A\nB")
        let collapsed = try LyricTranslation(phrases: [.init(lineIDs: [0, 1], text: "All words here")], document: doc)
        let key = LyricUnderstanding.translationKey(doc, source: "en", target: "es")
        try await cache.write(collapsed, key: key)
        let store = LyricTranslationStore(cache: cache) { _, _, _, _ in collapsed }
        await store.restore(doc, source: "en", target: "es")
        XCTAssertNil(store.results[key])
        do { _ = try await store.load(doc, source: "en", target: "es"); XCTFail() }
        catch MetadataLookupError.invalidResponse { }
        XCTAssertNil(store.results[key])
    }

    @MainActor func testDisablingAutomaticTranslationDropsWaitingWorkButFinishesActiveRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TranslationDisable.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite),
                                                 cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
        var calls = 0, held: [CheckedContinuation<Void, Never>] = []
        defer { for continuation in held { continuation.resume() } }
        let store = LyricTranslationStore(cache: MusicToolsCache(root: root), settings: settings, requests: CodexRequestPool()) { doc, _, _, _ in
            calls += 1
            await withCheckedContinuation { held.append($0) }
            return try LyricTranslation(lines: [0: "Traducido"], document: doc)
        }
        let owners = ["a", "b", "c", "d", "e"]
        store.setAutomaticQueue(owners, source: "en", target: "es")
        for owner in owners {
            await store.enqueue(LyricsDocument(text: owner), source: "en", target: "es", owner: owner, finishingPreparation: true)
        }
        try await wait { held.count == 4 }
        XCTAssertEqual(calls, 4)
        store.setAutomaticQueue([], source: "en", target: "es")
        let remaining = held; held.removeAll()
        for continuation in remaining { continuation.resume() }
        try await wait { store.results.count == 4 && store.pendingCount == 0 }
        XCTAssertEqual(calls, 4)
        store.retryAutomatic()
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testCacheIdentityReusesTimingEditsButNotChangedTextLanguagesOrOldAlgorithm() throws {
        let original = LyricUnderstanding.translationKey(lyric, source: "auto", target: "es")
        let retimed = LyricsDocument(text: "[00:02]When the rain stops\n[00:05]we will go outside.\n[00:08]\n[00:11]When the rain stops\n[00:13]we will go outside.")
        XCTAssertEqual(original, LyricUnderstanding.translationKey(retimed, source: "auto", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(LyricsDocument(text: "Changed words"), source: "auto", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(lyric, source: "en", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(lyric, source: "auto", target: "fr"))
        XCTAssertTrue(original.hasPrefix("codex-translation-v1:gpt-6.1-sol:medium:"))
    }

    @MainActor func testPreviousCodexCacheSurvivesModelChangeUntilExplicitRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root), document = LyricsDocument(text: "A tree grows.")
        let old = try LyricTranslation(lines: [0: "Un árbol crece."], document: document)
        let new = try LyricTranslation(lines: [0: "Crece un árbol."], document: document)
        let key = LyricUnderstanding.translationKey(document, source: "en", target: "es")
        let previousKey = LyricUnderstanding.translationKey(document, source: "en", target: "es",
                                                           model: "gpt-6-astra", effort: "xhigh")
        XCTAssertNotEqual(key, previousKey)
        try await cache.write(old, key: previousKey)
        let offline = LyricTranslationStore(cache: cache) { _, _, _, _ in
            XCTFail("Saved Codex translations must remain available offline")
            throw URLError(.notConnectedToInternet)
        }
        let restored = try await offline.load(document, source: "en", target: "es")
        XCTAssertEqual(restored, old)
        let currentBeforeRefresh = try await cache.read(LyricTranslation.self, key: key)
        XCTAssertNil(currentBeforeRefresh, "Do not relabel the previous model's saved output")
        var calls = 0
        let store = LyricTranslationStore(cache: cache) { _, _, _, refresh in
            XCTAssertTrue(refresh)
            calls += 1
            return new
        }
        let refreshed = try await store.load(document, source: "en", target: "es", refresh: true)
        XCTAssertEqual(refreshed, new)
        XCTAssertEqual(calls, 1)
        let reopened = LyricTranslationStore(cache: cache) { _, _, _, _ in
            XCTFail("The refreshed model's result must take precedence")
            throw URLError(.notConnectedToInternet)
        }
        let persisted = try await reopened.load(document, source: "en", target: "es")
        XCTAssertEqual(persisted, new)
        let previous = try await cache.read(LyricTranslation.self, key: previousKey)
        XCTAssertEqual(previous, old)
    }

    @MainActor func testCollapsedCachesAreRecomputedAndNewAlignmentPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root)
        let source = LyricsDocument(text: "[00:01]Night falls\n[00:03]We sing together")
        let key = LyricUnderstanding.translationKey(source, source: "en", target: "es")
        let collapsed = try LyricTranslation(phrases: [.init(lineIDs: [0, 1], text: "Cae la noche. Cantamos juntos.")], document: source)
        for version in [1, 2, 3, 4, 5] {
            let oldKey = "apple-translation-context-v\(version):en:es:" + String(key.split(separator: ":").last!)
            try await cache.write(collapsed, key: oldKey)
        }
        let previousKey = LyricUnderstanding.translationKey(source, source: "en", target: "es",
                                                           model: "gpt-6-astra", effort: "xhigh")
        try await cache.write(collapsed, key: previousKey)
        let expected = try LyricTranslation(lines: [0: "Cae la noche.", 1: "Cantamos juntos."], document: source)
        var calls = 0
        let store = LyricTranslationStore(cache: cache) { _, _, _, _ in calls += 1; return expected }
        let result = try await store.load(source, source: "en", target: "es")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(calls, 1, "Old grouped translations must be regenerated")
        let fresh = LyricTranslationStore(cache: cache) { _, _, _, _ in XCTFail("New alignment must be cached"); throw URLError(.unknown) }
        let restored = try await fresh.load(source, source: "en", target: "es")
        XCTAssertEqual(restored, expected)
    }

    @MainActor func testRequestsShareWorkAndPersistAfterOnlyObserverCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root)
        let entered = expectation(description: "Translator entered"), joined = expectation(description: "Observer joined")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = LyricTranslationStore(cache: cache) { document, _, _, _ in
            calls += 1
            await withCheckedContinuation { release = $0; entered.fulfill() }
            return try LyricTranslation(lines: [0: "Cuando pare la lluvia", 1: "saldremos.", 3: "Cuando pare la lluvia", 4: "saldremos."], document: document)
        }
        let first = Task { try await store.load(lyric, source: "en", target: "es") }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { joined.fulfill(); return try await store.load(lyric, source: "en", target: "es") }
        await fulfillment(of: [joined], timeout: 3)
        first.cancel(); second.cancel()
        release?.resume()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Observer cancellation must be retained") } catch is CancellationError { }
        }
        XCTAssertEqual(calls, 1)
        let fresh = LyricTranslationStore(cache: cache) { _, _, _, _ in XCTFail("Must restore from disk"); throw URLError(.unknown) }
        let result = try await fresh.load(lyric, source: "en", target: "es")
        XCTAssertEqual(result.lines[1], "saldremos.")
    }

    @MainActor func testManualRefreshReplacesCacheCoalescesAndPreservesResultOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root), document = LyricsDocument(text: "A tree grows.")
        let old = try LyricTranslation(lines: [0: "Un árbol crece."], document: document)
        let new = try LyricTranslation(lines: [0: "Crece un árbol."], document: document)
        let key = LyricUnderstanding.translationKey(document, source: "en", target: "es")
        try await cache.write(old, key: key)
        var calls = 0, release: CheckedContinuation<Void, Never>?, fail = false
        let entered = expectation(description: "Refreshing translation"), joined = expectation(description: "Refresh observer joined")
        let store = LyricTranslationStore(cache: cache) { _, _, _, _ in
            calls += 1
            if fail { throw URLError(.cannotConnectToHost) }
            await withCheckedContinuation { release = $0; entered.fulfill() }
            return new
        }
        let restored = try await store.load(document, source: "en", target: "es")
        XCTAssertEqual(restored, old); XCTAssertEqual(calls, 0)
        let first = Task { try await store.load(document, source: "en", target: "es", refresh: true) }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task {
            joined.fulfill()
            return try await store.load(document, source: "en", target: "es", refresh: true)
        }
        await fulfillment(of: [joined], timeout: 3)
        let whileRefreshing = try await store.load(document, source: "en", target: "es")
        XCTAssertEqual(whileRefreshing, old, "The displayed translation remains available during refresh")
        first.cancel()
        release?.resume()
        do { _ = try await first.value; XCTFail() } catch is CancellationError { }
        let refreshed = try await second.value
        XCTAssertEqual(refreshed, new); XCTAssertEqual(calls, 1)
        fail = true
        do { _ = try await store.load(document, source: "en", target: "es", refresh: true); XCTFail() }
        catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        XCTAssertEqual(store.results[key], new)
        let reopened = LyricTranslationStore(cache: cache) { _, _, _, _ in XCTFail("Must restore refreshed cache"); throw URLError(.unknown) }
        let persisted = try await reopened.load(document, source: "en", target: "es")
        XCTAssertEqual(persisted, new); XCTAssertEqual(calls, 2)
    }

    @MainActor func testParallelRequestsFailureRetryAndCachedBypass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LyricsDocument(text: "First song."), second = LyricsDocument(text: "Second song.")
        let entered = expectation(description: "Uncached translation blocked"), enqueued = expectation(description: "Next translation requested")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0, active = 0, maximumActive = 0
        let store = LyricTranslationStore(cache: MusicToolsCache(root: root)) { document, _, language, _ in
            calls += 1; active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if calls == 2 {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                throw URLError(.cannotConnectToHost)
            }
            return try LyricTranslation(lines: [0: "Translation \(language)"], document: document)
        }
        _ = try await store.load(first, source: "en", target: "es")
        let blocked = Task { try await store.load(second, source: "en", target: "es") }
        await fulfillment(of: [entered], timeout: 3)
        let later = Task { enqueued.fulfill(); return try await store.load(first, source: "en", target: "fr") }
        await fulfillment(of: [enqueued], timeout: 3)
        try await wait { calls == 3 }
        let cached = try await store.load(first, source: "en", target: "es")
        XCTAssertEqual(cached.lines[0], "Translation es")
        release?.resume()
        do { _ = try await blocked.value; XCTFail("Expected connection failure") } catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        _ = try await later.value
        XCTAssertEqual(store.statuses[LyricUnderstanding.translationKey(second, source: "en", target: "es")], .failed(URLError(.cannotConnectToHost).localizedDescription))
        _ = try await store.load(second, source: "en", target: "es")
        XCTAssertEqual(calls, 4); XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(store.statuses[LyricUnderstanding.translationKey(second, source: "en", target: "es")], .ready)
    }
}
