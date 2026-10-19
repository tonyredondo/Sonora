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
