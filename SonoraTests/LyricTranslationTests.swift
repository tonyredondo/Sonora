import Foundation
import SonoraCore
import XCTest
@testable import Sonora

final class LyricTranslationTests: XCTestCase {
    private let lyric = LyricsDocument(text: "[00:01]When the rain stops\n[00:03]we will go outside.\n[00:06]\n[00:07]When the rain stops\n[00:09]we will go outside.")

    func testWholeContextKeepsRepeatedLineIdentitiesAndOriginalTimes() throws {
        let input = try ContextualLyricText.input(lyric)
        XCTAssertEqual(String(input.characters), "When the rain stops we will go outside. When the rain stops we will go outside.")
        XCTAssertEqual(input.runs.compactMap { $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] }.map(\.absoluteString),
                       [0, 1, 3, 4].map { "sonora-lyric://line/\($0)" })
        var aligned = AttributedString()
        for (id, text) in [(0, "Cuando pare la lluvia "), (1, "saldremos. "), (3, "Cuando pare la lluvia "), (4, "saldremos.")] {
            var fragment = AttributedString(text)
            fragment[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += fragment
        }
        let result = try ContextualLyricText.translation(aligned, document: lyric)
        XCTAssertEqual(result.lines, [0: "Cuando pare la lluvia", 1: "saldremos.", 3: "Cuando pare la lluvia", 4: "saldremos."])
        XCTAssertEqual(lyric.lines.map(\.time), [1, 3, 6, 7, 9])
        XCTAssertEqual(lyric.lines[1].text, "we will go outside.")
    }

    func testUnknownOrAbsentAlignmentIsRejectedInsteadOfInventingTiming() throws {
        XCTAssertThrowsError(try ContextualLyricText.translation(AttributedString("Toda la traducción sin correspondencias"), document: lyric))
        var wrong = AttributedString("Texto")
        wrong[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/99")
        XCTAssertThrowsError(try ContextualLyricText.translation(wrong, document: lyric))
        XCTAssertThrowsError(try ContextualLyricText.input(LyricsDocument(text: "")))
        XCTAssertThrowsError(try ContextualLyricText.input(LyricsDocument(text: String(repeating: "word ", count: 25000))))
    }

    func testContextualAlignmentJoinsReorderedWordsAndImplicitPronouns() throws {
        let source = LyricsDocument(text: "[00:01]She bought a red\n[00:03]car yesterday.\n[00:06]\n[00:07]We\n[00:09]are free.")
        var aligned = AttributedString()
        // Real Apple output: the adjective moves after the noun, and the
        // Spanish verb carries the pronoun without a separate aligned word.
        for (id, text) in [(0, "Ella compró un "), (1, "coche "), (0, "rojo "), (1, "ayer. "), (4, "Somos libres.")] {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let value = try ContextualLyricText.translation(aligned, document: source)
        XCTAssertEqual(value.phrases?.map(\.lineIDs), [[0, 1], [3, 4]])
        XCTAssertEqual(value.lines, [0: "Ella compró un coche rojo ayer.", 3: "Somos libres."])
        XCTAssertEqual(value.phrases?.map(\.text).joined(separator: " "), String(aligned.characters))
        XCTAssertEqual(source.lines.map(\.time), [1, 3, 6, 7, 9])
        let restored = try JSONDecoder().decode(LyricTranslation.self, from: JSONEncoder().encode(value)).validated(for: source)
        XCTAssertEqual(restored, value)
    }

    func testBackwardAlignedConnectorDoesNotSwallowTheFinalTranslation() throws {
        let source = LyricsDocument(text: "[00:01]I miss everyone\n[00:04]and you")
        var aligned = AttributedString()
        // Real Apple output sends the second "a" back to the verb "miss".
        for (id, text) in [(0, "Echo de menos a todos "), (1, "y "), (0, "a "), (1, "ti")] {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: source, targetLanguage: .init(identifier: "es"))
        XCTAssertEqual(result.lines, [0: "Echo de menos a todos", 1: "y a ti"])
        XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0], [1]])
        XCTAssertEqual(result.phrases?.map(\.text).joined(separator: " "), String(aligned.characters))
        XCTAssertEqual(source.lines.map(\.time), [1, 4])
        let restored = try JSONDecoder().decode(LyricTranslation.self, from: JSONEncoder().encode(result)).validated(for: source)
        XCTAssertEqual(restored, result)
    }

    func testConnectorRepairPreservesTheWholeFinalPhraseAndRejectsUnknownLinks() throws {
        let source = LyricsDocument(text: "[00:01]You gotta fake it through it all\n[00:04]Lovers over love")
        var aligned = AttributedString()
        for (id, text) in [(0, "Tienes que fingirlo todo "), (1, "Amantes por encima "), (0, "del "), (1, "amor")] {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: source, targetLanguage: .init(identifier: "es"))
        XCTAssertEqual(result.lines, [0: "Tienes que fingirlo todo", 1: "Amantes por encima del amor"])
        var unknown = AttributedString(" y ")
        unknown[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/99")
        XCTAssertThrowsError(try ContextualLyricText.translation(aligned + unknown, document: source))
    }

    func testConnectorBoundariesIgnoreSurroundingWhitespaceAndUnalignedSeparators() throws {
        let source = LyricsDocument(text: "[00:01]I miss everyone\n[00:04]and you")
        let cases: [[(Int?, String)]] = [
            [(0, "Echo de menos a todos"), (1, " y"), (0, " a"), (1, " ti")],
            [(0, "Echo de menos a todos"), (1, " y"), (0, " a "), (1, "ti")],
            [(0, "Echo de menos a todos "), (1, "y"), (nil, " "), (0, "a"), (nil, " "), (1, "ti")],
            [(0, "Echo de menos a todos "), (1, "y"), (0, "\u{00a0}a\n"), (1, "ti")]
        ]
        for runs in cases {
            var aligned = AttributedString()
            for (id, text) in runs {
                var fragment = AttributedString(text)
                if let id { fragment.link = URL(string: "sonora-lyric://line/\(id)") }
                aligned += fragment
            }
            let result = try ContextualLyricText.translation(aligned, document: source, targetLanguage: .init(identifier: "es"))
            XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0], [1]])
            XCTAssertEqual(result.lines[0], "Echo de menos a todos")
            XCTAssertEqual(result.lines[1]?.split(whereSeparator: \.isWhitespace).joined(separator: " "), "y a ti")
            XCTAssertEqual(result.phrases?.map(\.text).joined().filter { !$0.isWhitespace },
                           String(aligned.characters).filter { !$0.isWhitespace })
        }
    }

    func testConnectorRepairNeverSplitsAWordAtAnAttributeBoundary() throws {
        let source = LyricsDocument(text: "[00:01]I can see\n[00:04]the sea")
        var aligned = AttributedString()
        for (id, text) in [(0, "Veo el "), (1, "m"), (0, "a"), (1, "r")] {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: source, targetLanguage: .init(identifier: "es"))
        XCTAssertEqual(result.phrases?.map(\.text), ["Veo el mar"])
        XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0, 1]])
    }

    func testClosingPunctuationDoesNotMergeDistinctTranslatedLines() throws {
        let source = LyricsDocument(text: """
        [00:01]The sun rises over the mountains
        [00:03]A bird sings in the garden
        [00:06]The train arrives at noon
        [00:09]We will meet by the river
        [00:12]The evening brings a gentle breeze
        [00:15]Tomorrow we begin again
        """)
        // Real Apple alignment: the next line's run starts with the previous
        // sentence's period. Only that punctuation belongs to the previous line.
        let runs = [
            (0, "El sol sale sobre las montañas. "),
            (1, "Un pájaro canta en el jardín"),
            (2, ". El tren llega al mediodía"),
            (3, ". Nos encontraremos junto al río"),
            (4, ". La noche trae una suave brisa"),
            (5, ". Mañana comenzamos de nuevo.")
        ]
        var aligned = AttributedString()
        for (id, text) in runs {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: source)
        XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0], [1], [2], [3], [4], [5]])
        XCTAssertEqual(result.lines, [
            0: "El sol sale sobre las montañas.",
            1: "Un pájaro canta en el jardín.",
            2: "El tren llega al mediodía.",
            3: "Nos encontraremos junto al río.",
            4: "La noche trae una suave brisa.",
            5: "Mañana comenzamos de nuevo."
        ])
        XCTAssertEqual(result.phrases?.map(\.text).joined(separator: " "), String(aligned.characters))
        XCTAssertEqual(source.lines.map(\.time), [1, 3, 6, 9, 12, 15])
    }

    func testPunctuationOnlyRunDoesNotConsumeNextLineOrOpeningPunctuation() throws {
        let source = LyricsDocument(text: "[00:01]Night falls\n[00:03]We sing together\n[00:05]Will you return tomorrow")
        var aligned = AttributedString()
        let runs: [(Int?, String)] = [(0, "Cae la noche"), (1, "."), (nil, " "),
                                      (1, "¡Cantamos juntos!"), (nil, "\n"), (2, "¿Volverás mañana?")]
        for (id, text) in runs {
            var part = AttributedString(text)
            if let id { part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)") }
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: source)
        XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0], [1], [2]])
        XCTAssertEqual(result.lines, [0: "Cae la noche.", 1: "¡Cantamos juntos!", 2: "¿Volverás mañana?"])
    }

    func testCommaSeparatesAlignedClausesWithoutLosingSentenceContext() throws {
        var aligned = AttributedString()
        for (id, text) in [(0, "Cuando pare la lluvia"), (1, ", saldremos. "),
                           (3, "Cuando pare la lluvia"), (4, ", saldremos.")] {
            var part = AttributedString(text)
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "sonora-lyric://line/\(id)")
            aligned += part
        }
        let result = try ContextualLyricText.translation(aligned, document: lyric)
        XCTAssertEqual(result.phrases?.map(\.lineIDs), [[0], [1], [3], [4]])
        XCTAssertEqual(result.lines, [0: "Cuando pare la lluvia,", 1: "saldremos.", 3: "Cuando pare la lluvia,", 4: "saldremos."])
        XCTAssertEqual(result.phrases?.map(\.text).joined(separator: " "), String(aligned.characters))
    }

    func testCacheIdentityReusesTimingEditsButNotChangedTextLanguagesOrOldAlgorithm() throws {
        guard #available(iOS 26.4, *) else { throw XCTSkip("Contextual translation requires iOS 26.4") }
        let original = LyricUnderstanding.translationKey(lyric, source: "auto", target: "es")
        let retimed = LyricsDocument(text: "[00:02]When the rain stops\n[00:05]we will go outside.\n[00:08]\n[00:11]When the rain stops\n[00:13]we will go outside.")
        XCTAssertEqual(original, LyricUnderstanding.translationKey(retimed, source: "auto", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(LyricsDocument(text: "Changed words"), source: "auto", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(lyric, source: "en", target: "es"))
        XCTAssertNotEqual(original, LyricUnderstanding.translationKey(lyric, source: "auto", target: "fr"))
        XCTAssertNotEqual(original, LyricUnderstanding.legacyTranslationKey(lyric, source: "auto", target: "es"))
    }

    @MainActor func testCollapsedCachesAreRecomputedAndNewAlignmentPersists() async throws {
        guard #available(iOS 26.4, *) else { throw XCTSkip("Contextual translation requires iOS 26.4") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MusicToolsCache(root: root)
        let source = LyricsDocument(text: "[00:01]Night falls\n[00:03]We sing together")
        let key = LyricUnderstanding.translationKey(source, source: "en", target: "es")
        let collapsed = try LyricTranslation(phrases: [.init(lineIDs: [0, 1], text: "Cae la noche. Cantamos juntos.")], document: source)
        for version in [2, 3, 4] {
            let oldKey = "apple-translation-context-v\(version):" + key.split(separator: ":").dropFirst().joined(separator: ":")
            try await cache.write(collapsed, key: oldKey)
        }
        let expected = try LyricTranslation(lines: [0: "Cae la noche.", 1: "Cantamos juntos."], document: source)
        var calls = 0
        let store = LyricTranslationStore(cache: cache) { _, _, _ in calls += 1; return expected }
        let result = try await store.load(source, source: "en", target: "es")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(calls, 1, "Old grouped translations must be regenerated")
        let fresh = LyricTranslationStore(cache: cache) { _, _, _ in XCTFail("New alignment must be cached"); throw URLError(.unknown) }
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
        let store = LyricTranslationStore(cache: cache) { document, _, _ in
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
        let fresh = LyricTranslationStore(cache: cache) { _, _, _ in XCTFail("Must restore from disk"); throw URLError(.unknown) }
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
        let store = LyricTranslationStore(cache: cache) { _, _, _ in
            calls += 1
            if fail { throw LyricTranslationIssue.needsLanguages }
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
        catch LyricTranslationIssue.needsLanguages { }
        XCTAssertEqual(store.results[key], new)
        let reopened = LyricTranslationStore(cache: cache) { _, _, _ in XCTFail("Must restore refreshed cache"); throw URLError(.unknown) }
        let persisted = try await reopened.load(document, source: "en", target: "es")
        XCTAssertEqual(persisted, new); XCTAssertEqual(calls, 2)
    }

    @MainActor func testSerialQueueFailureRetryAndCachedBypass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = LyricsDocument(text: "First song."), second = LyricsDocument(text: "Second song.")
        let entered = expectation(description: "Uncached translation blocked"), enqueued = expectation(description: "Next translation requested")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0, active = 0, maximumActive = 0
        let store = LyricTranslationStore(cache: MusicToolsCache(root: root)) { document, _, language in
            calls += 1; active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if calls == 2 {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                throw LyricTranslationIssue.needsLanguages
            }
            return try LyricTranslation(lines: [0: "Translation \(language)"], document: document)
        }
        _ = try await store.load(first, source: "en", target: "es")
        let blocked = Task { try await store.load(second, source: "en", target: "es") }
        await fulfillment(of: [entered], timeout: 3)
        let later = Task { enqueued.fulfill(); return try await store.load(first, source: "en", target: "fr") }
        await fulfillment(of: [enqueued], timeout: 3)
        let cached = try await store.load(first, source: "en", target: "es")
        XCTAssertEqual(cached.lines[0], "Translation es")
        release?.resume()
        do { _ = try await blocked.value; XCTFail("Expected missing language status") } catch LyricTranslationIssue.needsLanguages { }
        _ = try await later.value
        XCTAssertEqual(store.statuses[LyricUnderstanding.translationKey(second, source: "en", target: "es")], .needsLanguages)
        _ = try await store.load(second, source: "en", target: "es")
        XCTAssertEqual(calls, 4); XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(store.statuses[LyricUnderstanding.translationKey(second, source: "en", target: "es")], .ready)
    }
}
