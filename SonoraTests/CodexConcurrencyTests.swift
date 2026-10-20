import Foundation
import SonoraCore
import XCTest
@testable import Sonora

@MainActor
private final class CodexProbe {
    var calls: [String] = []
    var active: Set<String> = []
    var peak = 0
    var pending: [String: CheckedContinuation<Void, Error>] = [:]

    func request(_ id: String) async throws {
        calls.append(id)
        active.insert(id)
        peak = max(peak, active.count)
        defer { active.remove(id) }
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func finish(_ id: String, error: Error? = nil) {
        let continuation = pending.removeValue(forKey: id)
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
    func finishAll() {
        for id in Array(pending.keys) { finish(id) }
    }
}

@MainActor
final class CodexConcurrencyTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func response() throws -> LyricsInterpretation {
        try JSONDecoder().decode(LyricsInterpretation.self, from: Data(
            #"{"explanation":"A possible reading.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8))
    }
    private func settings(_ root: URL, defaults: UserDefaults) -> MetadataAssistantSettings {
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        return MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: UUID().uuidString),
                                         cache: MetadataLookupCache(directory: root.appendingPathComponent("metadata")))
    }

    func testBothToolsShareFourSlotsAndDuplicateObserversReuseActiveWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ParallelCodex.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let config = settings(root, defaults: defaults), pool = CodexRequestPool(), probe = CodexProbe()
        let reading = try response()
        let meanings = LyricInterpretationStore(settings: config, requests: pool) { doc, _, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            try await probe.request("m" + doc.lines[0].text)
            return reading
        }
        let translations = LyricTranslationStore(cache: MusicToolsCache(root: root), settings: config, requests: pool) { doc, _, _, _ in
            try await probe.request("t" + doc.lines[0].text)
            return try LyricTranslation(lines: [0: "Traducción"], document: doc)
        }
        defer { meanings.setAutomaticQueue([]); translations.setAutomaticQueue([]); probe.finishAll() }
        meanings.setAutomaticQueue(["1", "2", "3"])
        translations.setAutomaticQueue(["1", "2", "3"], source: "en", target: "es")
        for id in ["1", "2"] {
            let doc = LyricsDocument(text: id)
            await meanings.enqueue(doc, language: "es", owner: id)
            try await wait { probe.pending["m" + id] != nil }
            await translations.enqueue(doc, source: "en", target: "es", owner: id)
            try await wait { probe.pending["t" + id] != nil }
        }
        await meanings.enqueue(LyricsDocument(text: "3"), language: "es", owner: "3")
        await translations.enqueue(LyricsDocument(text: "3"), source: "en", target: "es", owner: "3")
        let observer = Task { try await translations.load(LyricsDocument(text: "1"), source: "en", target: "es") }
        await Task.yield()
        XCTAssertEqual(probe.calls.count, 4)
        XCTAssertEqual(probe.active.count, 4)
        probe.finish("m1")
        try await wait { probe.calls.count == 5 }
        XCTAssertEqual(probe.active.count, 4, "One completed request admits exactly one replacement")
        probe.finish("t1")
        let joined = try await observer.value
        XCTAssertEqual(joined.lines[0], "Traducción")
        try await wait { probe.calls.count == 6 }
        probe.finishAll()
        try await wait { meanings.results.count == 3 && translations.results.count == 3 }
        XCTAssertEqual(probe.peak, 4)
        XCTAssertEqual(Set(probe.calls).count, 6)
        XCTAssertEqual(probe.calls.count, 6, "The extra observer must not launch another request")
        XCTAssertEqual(meanings.pendingCount + translations.pendingCount, 0)
    }

    func testMeaningLateSuccessCannotClearNewerFailureOrRepeatSuccessfulWork() async throws {
        try await checkLateSuccess(translation: false)
    }
    func testTranslationLateSuccessCannotClearNewerFailureOrRepeatSuccessfulWork() async throws {
        try await checkLateSuccess(translation: true)
    }
    private func checkLateSuccess(translation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ParallelFailure.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let config = settings(root, defaults: defaults), pool = CodexRequestPool(), probe = CodexProbe()
        let reading = try response()
        let meanings = LyricInterpretationStore(settings: config, requests: pool) { doc, _, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            try await probe.request(doc.lines[0].text)
            return reading
        }
        let translations = LyricTranslationStore(cache: MusicToolsCache(root: root), settings: config, requests: pool) { doc, _, _, _ in
            try await probe.request(doc.lines[0].text)
            return try LyricTranslation(lines: [0: "Traducción"], document: doc)
        }
        defer { meanings.setAutomaticQueue([]); translations.setAutomaticQueue([]); probe.finishAll() }
        let owners = ["1", "2", "3", "4", "5"]
        meanings.setAutomaticQueue(owners)
        translations.setAutomaticQueue(owners, source: "en", target: "es")
        for id in owners {
            let doc = LyricsDocument(text: id)
            if translation { await translations.enqueue(doc, source: "en", target: "es", owner: id) }
            else { await meanings.enqueue(doc, language: "es", owner: id) }
        }
        let issue = { translation ? translations.automaticIssue : meanings.automaticIssue }
        let count = { translation ? translations.results.count : meanings.results.count }
        let pending = { translation ? translations.pendingCount : meanings.pendingCount }
        try await wait { probe.pending.count == 4 }
        probe.finish("1", error: URLError(.cannotConnectToHost))
        try await wait { issue() != nil }
        probe.finishAll()
        try await wait { count() == 3 }
        XCTAssertNotNil(issue(), "Older successful requests must not clear the newer connection failure")
        XCTAssertEqual(probe.calls, ["1", "2", "3", "4"], "The fifth request must remain paused")
        XCTAssertEqual(pending(), 2, "Only the failed and unstarted requests remain")
        if translation { translations.retryAutomatic() } else { meanings.retryAutomatic() }
        try await wait { probe.pending.count == 2 }
        XCTAssertEqual(probe.calls, ["1", "2", "3", "4", "1", "5"])
        probe.finishAll()
        try await wait { count() == 5 && pending() == 0 }
        XCTAssertNil(issue())
    }
}
