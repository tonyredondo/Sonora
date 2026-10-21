import CryptoKit
import Foundation
import XCTest
@testable import SonoraCore

private actor InterpretationHTTP: MetadataLookupTransport {
    var calls: [URLRequest] = []
    var response = MetadataHTTPResponse(data: Data(#"{"explanation":"A possible reading of growth and patience.","model":"gpt-6-astra","effort":"medium"}"#.utf8), status: 200, contentType: "application/json")
    func send(_ request: URLRequest) throws -> MetadataHTTPResponse { calls.append(request); return response }
    func set(_ data: String, status: Int) { response = MetadataHTTPResponse(data: Data(data.utf8), status: status, contentType: "application/json") }
}
final class LyricsInterpretationTests: XCTestCase {
    func testSongContextIsSentAndSeparatesEveryCacheInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let client = LyricsInterpretationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http)
        let context = LyricsInterpretationContext(title: "November", artist: "Love Division", album: "November Songs",
                                                 styles: ["Rock---Indie Rock"], moods: ["sad", "relaxed"])
        let first = try await client.interpret(lyrics: "Leaves fall.", language: "es", context: context, offline: false)
        let calls = await http.calls
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["effort"] as? String, "medium")
        let song = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual(song["title"] as? String, "November")
        XCTAssertEqual(song["artist"] as? String, "Love Division")
        XCTAssertEqual(song["album"] as? String, "November Songs")
        XCTAssertEqual(song["styles"] as? [String], ["Rock---Indie Rock"])
        XCTAssertEqual(song["moods"] as? [String], ["sad", "relaxed"])
        let reopened = LyricsInterpretationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http)
        let restored = try await reopened.interpret(lyrics: "Leaves fall.", language: "es", context: context, offline: true)
        XCTAssertEqual(restored, first)
        for changed in [
            LyricsInterpretationContext(title: "Ghosts", artist: context.artist, album: context.album, styles: context.styles, moods: context.moods),
            LyricsInterpretationContext(title: context.title, artist: "Other", album: context.album, styles: context.styles, moods: context.moods),
            LyricsInterpretationContext(title: context.title, artist: context.artist, album: "Other", styles: context.styles, moods: context.moods),
            LyricsInterpretationContext(title: context.title, artist: context.artist, album: context.album, styles: ["Rock---Alternative Rock"], moods: context.moods),
            LyricsInterpretationContext(title: context.title, artist: context.artist, album: context.album, styles: context.styles, moods: ["happy"])
        ] {
            do { _ = try await reopened.interpret(lyrics: "Leaves fall.", language: "es", context: changed, offline: true); XCTFail("Changed context must not reuse another meaning") }
            catch MetadataLookupError.notCached { }
        }
        let finalCalls = await http.calls
        XCTAssertEqual(finalCalls.count, 1)
    }

    func testInvalidContextNeverSendsARequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP()
        let client = LyricsInterpretationClient(connection: try .init(endpoint: "http://localhost:8089", token: ""), cache: MetadataLookupCache(directory: root), transport: http)
        for context in [LyricsInterpretationContext(title: String(repeating: "a", count: 4097)),
                        .init(artist: "Artist\u{0}Name"), .init(styles: [" "]), .init(styles: ["A", "B", "C"]),
                        .init(moods: ["invented"])] {
            do { _ = try await client.interpret(lyrics: "Leaves fall.", language: "es", context: context, offline: false); XCTFail() }
            catch MetadataLookupError.invalidSearch { }
        }
        let calls = await http.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testRefreshBypassesCachesAndRetainsLastGoodResultOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let cache = MetadataLookupCache(directory: root)
        let client = LyricsInterpretationClient(connection: connection, cache: cache, transport: http)
        let first = try await client.interpret(lyrics: "A tree grows", language: "es", offline: false)
        await http.set(#"{"explanation":"A new reading.","model":"gpt-6-astra","effort":"medium"}"#, status: 200)
        let updated = try await client.interpret(lyrics: "A tree grows", language: "es", offline: false, refresh: true)
        XCTAssertNotEqual(first, updated)
        var calls = await http.calls
        XCTAssertEqual(calls.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["refresh"] as? Bool, true)
        XCTAssertEqual(body["lyrics"] as? String, "A tree grows")

        // The refresh flag must not create a separate cache entry.
        let reopened = LyricsInterpretationClient(connection: connection, cache: cache, transport: http)
        let cached = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: true)
        XCTAssertEqual(cached, updated)
        do {
            _ = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: true, refresh: true)
            XCTFail("An offline refresh must not report a cached answer as newly generated")
        } catch MetadataLookupError.notCached { }

        await http.set(#"{"error":"codex_unavailable"}"#, status: 503)
        do {
            _ = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: false, refresh: true)
            XCTFail("Refresh failure must reach its caller")
        } catch LyricsInterpretationError.service { }
        let preserved = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: true)
        XCTAssertEqual(preserved, updated)
        calls = await http.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testCacheSurvivesRecreationAndSeparatesTextAndLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "private-fixture-token")
        let client = LyricsInterpretationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http)
        let first = try await client.interpret(lyrics: "A tree grows", language: "es", offline: false)
        let reopened = LyricsInterpretationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http)
        let cached = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: true)
        XCTAssertEqual(first, cached)
        do { _ = try await reopened.interpret(lyrics: "A tree grows", language: "en", offline: true); XCTFail("A different language needs its own cached result") } catch MetadataLookupError.notCached { }
        do { _ = try await reopened.interpret(lyrics: "Changed", language: "es", offline: true); XCTFail("Edited lyrics need their own cached result") } catch MetadataLookupError.notCached { }
        let calls = await http.calls; XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].url?.path, "/v1/lyrics/interpret")
        XCTAssertEqual(calls[0].value(forHTTPHeaderField: "Authorization"), "Bearer private-fixture-token")
        XCTAssertFalse(String(decoding: calls[0].httpBody!, as: UTF8.self).contains("token"))
    }
    func testFailuresAndWrongModelNeverBecomeCachedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let client = LyricsInterpretationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http)
        await http.set(#"{"error":"codex_limit","message":"private upstream message must not be displayed"}"#, status: 429)
        do { _ = try await client.interpret(lyrics: "Tree", language: "es", offline: false); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("límite")); XCTAssertFalse(error.localizedDescription.contains("private upstream")) }
        for (model, effort) in [("other", "medium"), ("gpt-6-astra", "xhigh"), ("gpt-6-astra", "low")] {
            let data = try JSONSerialization.data(withJSONObject: ["explanation": "Unexpected response", "model": model, "effort": effort])
            await http.set(String(decoding: data, as: UTF8.self), status: 200)
            do { _ = try await client.interpret(lyrics: "Tree", language: "es", offline: false); XCTFail() } catch MetadataLookupError.invalidResponse { }
        }
        do { _ = try await client.interpret(lyrics: "Tree", language: "es", offline: true); XCTFail() } catch MetadataLookupError.notCached { }
    }

    func testPreviousSongCacheIsIgnoredAndMediumIsGeneratedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let cache = MetadataLookupCache(directory: root)
        struct Legacy: Encodable { let lyrics = "A tree grows"; let language = "es"; let context = LyricsInterpretationContext(); var effort: String? }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(Legacy())).map { String(format: "%02x", $0) }.joined()
        let key = "codex-meaning-v2:gpt-6-astra:xhigh:\(connection.endpoint.absoluteString):\(digest)"
        let legacy = Data(#"{"explanation":"Saved interpretation.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8)
        try await cache.store(legacy, key: key, status: 200)
        let previousDigest = SHA256.hash(data: try encoder.encode(Legacy(effort: "medium"))).map { String(format: "%02x", $0) }.joined()
        let previousKey = "codex-meaning-v2:gpt-6-astra:medium:\(connection.endpoint.absoluteString):\(previousDigest)"
        let previous = Data(#"{"explanation":"Previous medium interpretation.","model":"gpt-6-astra","effort":"medium"}"#.utf8)
        try await cache.store(previous, key: previousKey, status: 200)
        let client = LyricsInterpretationClient(connection: connection, cache: cache, transport: http)
        do { _ = try await client.interpret(lyrics: "A tree grows", language: "es", offline: true); XCTFail("Previous interpretation must not be shown after the reset") }
        catch MetadataLookupError.notCached { }
        let updated = try await client.interpret(lyrics: "A tree grows", language: "es", offline: false)
        XCTAssertEqual(updated.effort, "medium")
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(try XCTUnwrap(calls.first).httpBody)) as? [String: Any])
        XCTAssertEqual(body["effort"] as? String, "medium")
        XCTAssertNil(body["refresh"])
        let reopened = LyricsInterpretationClient(connection: connection, cache: .init(directory: root), transport: http)
        let preferred = try await reopened.interpret(lyrics: "A tree grows", language: "es", offline: true)
        XCTAssertEqual(preferred, updated)
        let oldEntry = try await cache.read(key: key)
        XCTAssertEqual(oldEntry?.data, legacy)
    }
}
