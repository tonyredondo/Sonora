import Foundation
import XCTest
@testable import SonoraCore

private actor InterpretationHTTP: MetadataLookupTransport {
    var calls: [URLRequest] = []
    var response = MetadataHTTPResponse(data: Data(#"{"explanation":"A possible reading of growth and patience.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8), status: 200, contentType: "application/json")
    func send(_ request: URLRequest) throws -> MetadataHTTPResponse { calls.append(request); return response }
    func set(_ data: String, status: Int) { response = MetadataHTTPResponse(data: Data(data.utf8), status: status, contentType: "application/json") }
}
final class LyricsInterpretationTests: XCTestCase {
    func testRefreshBypassesCachesAndRetainsLastGoodResultOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = InterpretationHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let cache = MetadataLookupCache(directory: root)
        let client = LyricsInterpretationClient(connection: connection, cache: cache, transport: http)
        let first = try await client.interpret(lyrics: "A tree grows", language: "es", offline: false)
        await http.set(#"{"explanation":"A new reading.","model":"gpt-6-astra","effort":"xhigh"}"#, status: 200)
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
        await http.set(#"{"explanation":"Wrong model", "model":"other", "effort":"xhigh"}"#, status: 200)
        do { _ = try await client.interpret(lyrics: "Tree", language: "es", offline: false); XCTFail() } catch MetadataLookupError.invalidResponse { }
        do { _ = try await client.interpret(lyrics: "Tree", language: "es", offline: true); XCTFail() } catch MetadataLookupError.notCached { }
    }
}
