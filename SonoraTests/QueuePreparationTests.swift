import AVFAudio
import Foundation
import SonoraCore
import XCTest
@testable import Sonora

private actor QueueMeaningHTTP: MetadataLookupTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        calls += 1
        return MetadataHTTPResponse(data: Data(#"{"explanation":"A possible reading of growth.","model":"gpt-6-astra","effort":"medium"}"#.utf8),
                                    status: 200, contentType: "application/json")
    }
}

@MainActor
final class QueuePreparationTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func value(_ text: String = "A possible reading.") throws -> LyricsInterpretation {
        try JSONDecoder().decode(LyricsInterpretation.self, from: JSONSerialization.data(withJSONObject: [
            "explanation": text, "model": "gpt-6-astra", "effort": "xhigh"
        ]))
    }
    private func settings(_ root: URL, defaults: UserDefaults) -> MetadataAssistantSettings {
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        return MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: "QueueTests.\(UUID())"),
                                         cache: MetadataLookupCache(directory: root.appendingPathComponent("meaning")))
    }
    private func scope() throws -> (URL, String, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "QueueTests.\(UUID())"
        return (root, suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testMeaningParallelizesCoalescesAndPrioritizesUnstartedWork() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let response = try value()
        var calls: [String] = []
        var pending: [String: CheckedContinuation<LyricsInterpretation, Never>] = [:]
        defer { for continuation in pending.values { continuation.resume(returning: response) } }
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults), requests: CodexRequestPool()) { doc, _, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            let text = doc.lines[0].text
            calls.append(text)
            return await withCheckedContinuation { pending[text] = $0 }
        }
        let documents = ["A", "B", "C", "D", "E", "F"].map { LyricsDocument(text: $0) }
        store.setAutomaticQueue(["A", "B", "C", "D", "E", "F"])
        for doc in documents { await store.enqueue(doc, language: "es", owner: doc.lines[0].text) }
        try await wait { pending.count == 4 }
        XCTAssertEqual(calls, ["A", "B", "C", "D"])
        let manual = Task { try await store.load(documents[0], language: "es") }
        await Task.yield()
        store.setAutomaticQueue(["F", "A", "B", "C", "D", "E"])
        pending.removeValue(forKey: "A")?.resume(returning: response)
        let joined = try await manual.value
        XCTAssertEqual(joined, response)
        try await wait { calls.count == 5 }
        XCTAssertEqual(calls, ["A", "B", "C", "D", "F"])
        // E has not started; the other four active requests must finish and cache.
        store.setAutomaticQueue([])
        let remaining = pending; pending.removeAll()
        for continuation in remaining.values { continuation.resume(returning: response) }
        try await wait { store.results.count == 5 && store.pendingCount == 0 }
        XCTAssertEqual(calls.count, 5)
        XCTAssertNil(store.statuses[store.key(documents[4], language: "es")])
    }

    func testMeaningRefreshWaitsForActiveCachedRequestAndCoalescesWithoutLosingPreviousResult() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let old = try value("Old reading."), updated = try value("Updated reading.")
        var calls: [LyricInterpretationStore.RequestMode] = []
        var pending: CheckedContinuation<LyricsInterpretation, Error>?
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults)) { _, _, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            calls.append(mode)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let document = LyricsDocument(text: "A tree grows.")
        let normal = Task { try await store.load(document, language: "es") }
        try await wait { pending != nil }
        let refresh = Task { try await store.load(document, language: "es", refresh: true) }
        let another = Task { try await store.load(document, language: "es", refresh: true) }
        await Task.yield()
        pending?.resume(returning: old); pending = nil
        let original = try await normal.value
        XCTAssertEqual(original, old)
        try await wait { calls.count == 2 && pending != nil }
        XCTAssertEqual(calls, [.useCache, .refresh])
        let displayed = try await store.load(document, language: "es")
        XCTAssertEqual(displayed, old)
        pending?.resume(returning: updated); pending = nil
        let a = try await refresh.value, b = try await another.value
        XCTAssertEqual(a, updated); XCTAssertEqual(b, updated)
        XCTAssertEqual(calls.count, 2)
        let failed = Task { try await store.load(document, language: "es", refresh: true) }
        try await wait { pending != nil }
        pending?.resume(throwing: URLError(.cannotConnectToHost)); pending = nil
        do { _ = try await failed.value; XCTFail() } catch { }
        XCTAssertEqual(store.results[store.key(document, language: "es")], updated)
        XCTAssertEqual(store.pendingCount, 0, "A failed explicit refresh must not silently retry in the background")
    }

    func testOfflineMeaningWaitsAndServerFailurePausesOnlyAutomaticRequests() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let config = settings(root, defaults: defaults); config.offline = true
        let response = try value()
        var calls = 0, fail = true
        let store = LyricInterpretationStore(settings: config) { _, _, _, cached in
            if cached == .cachedOnly { throw MetadataLookupError.notCached }
            calls += 1
            if fail { throw URLError(.cannotConnectToHost) }
            return response
        }
        let a = LyricsDocument(text: "A"), b = LyricsDocument(text: "B")
        store.setAutomaticQueue(["a", "b"])
        await store.enqueue(a, language: "es", owner: "a")
        await store.enqueue(b, language: "es", owner: "b")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.statuses[store.key(a, language: "es")], .queued)
        config.offline = false
        try await wait { store.automaticIssue != nil }
        XCTAssertEqual(calls, 1)
        await store.enqueue(a, language: "es", owner: "a")
        XCTAssertEqual(calls, 1, "Selecting again must not retry an unavailable server")
        fail = false; store.retryAutomatic()
        await store.enqueue(a, language: "es", owner: "a")
        try await wait { store.results.count == 2 }
        XCTAssertEqual(calls, 3)
    }

    func testMeaningReusesTimingButSeparatesTextLanguageAndServer() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults))
        let a = LyricsDocument(text: "[00:01]A"), moved = LyricsDocument(text: "[00:05]A")
        XCTAssertEqual(store.key(a, language: "es"), store.key(moved, language: "es"))
        XCTAssertNotEqual(store.key(a, language: "es"), store.key(a, language: "en"))
        XCTAssertNotEqual(store.key(a, language: "es"), store.key(LyricsDocument(text: "B"), language: "es"))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: suite + ".other"))
        defer { otherDefaults.removePersistentDomain(forName: suite + ".other") }
        otherDefaults.set("http://localhost:9999", forKey: "metadata.endpoint")
        let other = MetadataAssistantSettings(defaults: otherDefaults, tokens: MetadataTokenStore(service: suite),
                                              cache: MetadataLookupCache(directory: root))
        XCTAssertNotEqual(store.key(a, language: "es"), LyricInterpretationStore(settings: other).key(a, language: "es"))
    }

    func testMeaningKeepsSongContextInTheJobAndReusesRetimedLyrics() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var contexts: [LyricsInterpretationContext] = []
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults)) { _, _, context, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            contexts.append(context)
            return try self.value(context.title + ":" + context.moods.joined(separator: ","))
        }
        let lyrics = LyricsDocument(text: "[00:01]Remember me"), moved = LyricsDocument(text: "[00:04]Remember me")
        let a = LyricsInterpretationContext(title: "November", artist: "Love Division", album: "November Songs", styles: ["Rock---Indie Rock"], moods: ["sad"])
        let b = LyricsInterpretationContext(title: "Ghosts", artist: "Other artist", album: "Other album", styles: ["Pop---Indie Pop"], moods: ["happy"])
        let first = try await store.load(lyrics, language: "es", context: a)
        let retimed = try await store.load(moved, language: "es", context: a)
        let second = try await store.load(lyrics, language: "es", context: b)
        XCTAssertEqual(first, retimed)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(contexts, [a, b])
        XCTAssertEqual(store.results[store.key(moved, language: "es", context: a)], first)
        XCTAssertEqual(store.results[store.key(lyrics, language: "es", context: b)], second)
    }

    func testDisablingMeaningDuringAFailedRequestDoesNotRetryItOnReconnect() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let response = try value()
        var calls = 0, pending: CheckedContinuation<LyricsInterpretation, Error>?
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults)) { _, _, _, cached in
            if cached == .cachedOnly { throw MetadataLookupError.notCached }
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return response
        }
        let document = LyricsDocument(text: "A")
        store.setAutomaticQueue(["a"])
        await store.enqueue(document, language: "es", owner: "a")
        try await wait { pending != nil }
        store.setAutomaticQueue([])
        pending?.resume(throwing: URLError(.cannotConnectToHost)); pending = nil
        try await wait { store.automaticIssue != nil }
        store.retryAutomatic()
        await store.enqueue(document, language: "es", owner: "a")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, 1, "A removed or disabled automatic request must not restart after its active attempt fails")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testMeaningLanguageChangeDropsUnstartedOldLanguageAndKeepsActiveResults() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let response = try value()
        var calls: [String] = [], pending: [String: CheckedContinuation<LyricsInterpretation, Never>] = [:]
        defer { for continuation in pending.values { continuation.resume(returning: response) } }
        let store = LyricInterpretationStore(settings: settings(root, defaults: defaults), requests: CodexRequestPool()) { doc, lang, _, mode in
            if mode == .cachedOnly { throw MetadataLookupError.notCached }
            let id = doc.lines[0].text + ":" + lang
            calls.append(id)
            return await withCheckedContinuation { pending[id] = $0 }
        }
        let owners = ["A", "B", "C", "D", "E"]
        store.setAutomaticQueue(owners, language: "es")
        for owner in owners { await store.enqueue(LyricsDocument(text: owner), language: "es", owner: owner) }
        try await wait { pending.count == 4 }
        let e = LyricsDocument(text: "E")
        store.setAutomaticQueue(owners, language: "en")
        await store.enqueue(e, language: "es", owner: "E")
        XCTAssertNil(store.statuses[store.key(e, language: "es")])
        await store.enqueue(e, language: "en", owner: "E")
        pending.removeValue(forKey: "A:es")?.resume(returning: response)
        try await wait { pending["E:en"] != nil }
        XCTAssertEqual(calls, ["A:es", "B:es", "C:es", "D:es", "E:en"])
        let remaining = pending; pending.removeAll()
        for continuation in remaining.values { continuation.resume(returning: response) }
        try await wait { store.results.count == 5 }
        XCTAssertNil(store.results[store.key(e, language: "es")])
        XCTAssertEqual(store.results[store.key(LyricsDocument(text: "A"), language: "es")], response)
    }

    func testLocalQueueReconcilesOrderRemovalDuplicatesAndFailuresWithoutCancellingActive() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let folder = try ScopedFolder(root)
        let items = try ["a.wav", "b.wav", "c.wav", "d.wav"].map {
            QueuePreparationStore.Item(track: try XCTUnwrap(AudioTrack(relativePath: $0)), folder: folder)
        }
        var calls: [String] = [], pending: CheckedContinuation<Void, Never>?
        let store = QueuePreparationStore { item, _ in
            calls.append(item.track.filename)
            if item.track.filename == "a.wav" { await withCheckedContinuation { pending = $0 } }
            if item.track.filename == "c.wav" { throw CocoaError(.fileReadCorruptFile) }
        }
        let preferences = QueuePreparationPreferences(defaults: defaults)
        XCTAssertTrue(preferences.audio && preferences.character && preferences.translation && preferences.meaning)
        store.update(items, preferences: preferences)
        try await wait { calls.count == 1 }
        store.update([items[3], items[2], items[3]], preferences: preferences)
        pending?.resume(); pending = nil
        try await wait { !store.isRunning }
        XCTAssertEqual(calls, ["a.wav", "d.wav", "c.wav"])
        XCTAssertEqual(store.issues.count, 1)
        store.update([items[3], items[2]], preferences: preferences)
        XCTAssertEqual(calls.count, 3)
        store.update([items[3]], preferences: preferences, retry: true)
        try await wait { calls.count == 4 }
        XCTAssertTrue(store.issues.isEmpty)
    }

    func testEntireUnplayedQueuePreparesAudioTranslationAndMeaningWithoutChangingPlayback() async throws {
        let (root, suite, defaults) = try scope()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let folderURL = root.appendingPathComponent("songs")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        for index in 1...3 {
            let url = folderURL.appendingPathComponent("\(index).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            for i in 0..<8000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.2)) * Float(index) * 0.1 }
            for _ in 0..<3 { try file.write(from: buffer) }
            try "[00:00]The tree grows \(index)\n[00:01]in the sun.".write(
                to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        }
        let cache = MusicToolsCache(root: root.appendingPathComponent("tools"))
        let tools = MusicToolsStore(cache: cache)
        var translated: [String] = [], interpreted: [String] = [], characterized: [String] = []
        var translationGate: CheckedContinuation<Void, Never>?
        var characterGate: CheckedContinuation<Void, Never>?
        defer { translationGate?.resume(); characterGate?.resume() }
        let config = settings(root, defaults: defaults), http = QueueMeaningHTTP()
        let characterValue = try JSONDecoder().decode(AudioCharacter.self, from: Data(#"{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Indie Rock","score":0.3}],"moods":{"happy":0.2,"sad":0.8,"relaxed":0.9,"aggressive":0.1}}"#.utf8))
        let character = AudioCharacterStore(settings: config, cache: cache) { track, _, _, _ in
            characterized.append(track.filename)
            if characterized.count == 1 { await withCheckedContinuation { characterGate = $0 } }
            return characterValue
        }
        let translations = LyricTranslationStore(cache: cache, settings: config) { doc, _, _, _ in
            translated.append(doc.lines[0].text)
            if translated.count == 1 { await withCheckedContinuation { translationGate = $0 } }
            return try LyricTranslation(lines: [0: "El árbol crece", 1: "al sol."], document: doc)
        }
        let connection = try MetadataProxyConnection(endpoint: config.endpoint, token: "fixture-only")
        let client = LyricsInterpretationClient(connection: connection, cache: config.cache, transport: http)
        let meanings = LyricInterpretationStore(settings: config) { doc, language, context, cached in
            if cached != .cachedOnly {
                XCTAssertEqual(context.styles, ["Rock---Indie Rock"])
                XCTAssertEqual(context.moods, ["sad", "relaxed"])
                XCTAssertFalse(context.title.isEmpty)
                XCTAssertFalse(characterized.isEmpty, "Meaning must wait for its audio tags")
                XCTAssertEqual(translations.statuses[LyricUnderstanding.translationKey(doc, source: "auto", target: "es")]?.busy == true || translations.results[LyricUnderstanding.translationKey(doc, source: "auto", target: "es")] != nil, true,
                               "Local preparation schedules both remote tools without waiting for translation")
                interpreted.append(doc.lines[0].text)
            }
            return try await client.interpret(lyrics: doc.lines.map(\.text).joined(separator: "\n"), language: language,
                                              context: context, offline: cached == .cachedOnly, refresh: cached == .refresh)
        }
        let player = PlaybackController(defaults: defaults, musicTools: tools, lyricTranslations: translations, lyricInterpretations: meanings, audioCharacter: character)
        defer { player.stop() }
        await player.loadFolder(folderURL, autoPlay: false)
        try await wait { characterGate != nil }
        XCTAssertTrue(interpreted.isEmpty, "Meaning must not start while tags are still preparing")
        characterGate?.resume(); characterGate = nil
        let selected = player.current?.id
        player.seek(to: 1.25)
        try await wait { translationGate != nil && meanings.results.count == 3 && characterized.count == 3 && !player.queuePreparation.isRunning }
        XCTAssertNil(translations.results[LyricUnderstanding.translationKey(LyricsDocument(text: "[00:00]The tree grows 1\n[00:01]in the sun."), source: "auto", target: "es")], "The first request is still running while other songs can finish")
        for track in player.queue.tracks {
            XCTAssertNotNil(tools.summary(for: track, folder: try player.folderAccess(for: track)),
                            "Slow translation must not block audio preparation for the rest of the queue")
        }
        translationGate?.resume(); translationGate = nil
        try await wait { meanings.results.count == 3 && translations.results.count == 3 && !player.queuePreparation.isRunning }
        XCTAssertEqual(interpreted, ["The tree grows 1", "The tree grows 2", "The tree grows 3"])
        XCTAssertEqual(translated.count, 3)
        XCTAssertEqual(characterized.count, 3)
        for track in player.queue.tracks {
            let access = try player.folderAccess(for: track)
            let toolsResult = try XCTUnwrap(tools.summary(for: track, folder: access))
            XCTAssertEqual(character.summary(track, folder: access, expected: toolsResult.fingerprint), characterValue)
        }
        XCTAssertEqual(player.current?.id, selected)
        XCTAssertEqual(player.currentTime, 1.25, accuracy: 0.01)
        XCTAssertFalse(player.isPlaying)
        defaults.set(false, forKey: "prepareQueueMeaning")
        player.preparationPreferencesDidChange()
        player.retryQueuePreparation()
        try await wait { !player.queuePreparation.isRunning && player.songAnalysisProgress == nil }
        XCTAssertEqual(interpreted.count, 3)
        XCTAssertEqual(translated.count, 3, "Retry must reuse completed translations")
        // Recreate every store and the player. All unplayed songs must restore
        // from disk, including meaning while the server is unavailable.
        defaults.set(true, forKey: "prepareQueueMeaning")
        config.offline = true
        let reopenedMeanings = LyricInterpretationStore(settings: config)
        let reopenedTools = MusicToolsStore(cache: cache) { _, _, _ in
            XCTFail("Previously prepared audio must not be decoded again")
            throw URLError(.unknown)
        }
        let reopenedTranslations = LyricTranslationStore(cache: cache, settings: config) { _, _, _, _ in
            XCTFail("Previously prepared lyrics must not be translated again")
            throw URLError(.unknown)
        }
        let reopenedCharacter = AudioCharacterStore(settings: config, cache: cache) { _, _, _, _ in
            XCTFail("Previously prepared tags must restore without a server or model call"); return characterValue
        }
        let reopened = PlaybackController(defaults: defaults, musicTools: reopenedTools,
                                          lyricTranslations: reopenedTranslations, lyricInterpretations: reopenedMeanings, audioCharacter: reopenedCharacter)
        defer { reopened.stop() }
        await reopened.restoreFolder()
        try await wait { reopenedMeanings.results.count == 3 }
        try await wait {
            reopened.queue.tracks.allSatisfy { track in
                guard let access = try? reopened.folderAccess(for: track), let result = reopenedTools.summary(for: track, folder: access) else { return false }
                return reopenedCharacter.summary(track, folder: access, expected: result.fingerprint) != nil
            }
        }
        XCTAssertEqual(reopened.queue.tracks.count, 3)
        XCTAssertEqual(reopened.current?.id, selected)
        XCTAssertEqual(reopened.currentTime, 1.25, accuracy: 0.01)
        XCTAssertFalse(reopened.isPlaying)
        let remoteCalls = await http.calls
        XCTAssertEqual(remoteCalls, 3)
        let selectedTrack = try XCTUnwrap(player.current), snapshot = try await player.readMetadata(for: selectedTrack)
        let namedContext = player.interpretationContext(for: selectedTrack, folder: try player.folderAccess(for: selectedTrack),
            values: [.title: "November", .artist: "Love Division", .album: "November Songs"], expected: snapshot.fingerprint)
        XCTAssertEqual(namedContext.title, "November")
        XCTAssertEqual(namedContext.artist, "Love Division")
        XCTAssertEqual(namedContext.album, "November Songs")
        XCTAssertEqual(namedContext.styles, ["Rock---Indie Rock"])
        XCTAssertEqual(namedContext.moods, ["sad", "relaxed"])
        // A later enqueue must trigger preparation too. This copy deliberately
        // shares audio/text identities, so audio and translation are reusable.
        // The different title still requires its own meaning context.
        try FileManager.default.copyItem(at: folderURL.appendingPathComponent("3.wav"), to: folderURL.appendingPathComponent("4.wav"))
        try FileManager.default.copyItem(at: folderURL.appendingPathComponent("1.lrc"), to: folderURL.appendingPathComponent("4.lrc"))
        let fourth = try XCTUnwrap(AudioTrack(relativePath: "4.wav"))
        let scope = try reopened.folderAccess(for: fourth)
        reopened.enqueue(fourth, playNext: true)
        try await wait { reopenedTools.summary(for: fourth, folder: scope) != nil && !reopened.queuePreparation.isRunning }
        XCTAssertEqual(reopened.queue.tracks.map(\.filename), ["1.wav", "4.wav", "2.wav", "3.wav"])
        XCTAssertEqual(reopened.current?.id, selected)
        XCTAssertFalse(reopened.isPlaying)
    }
}
