import CryptoKit
import Foundation
import XCTest
@testable import SonoraCore

private actor AlbumHTTP: MetadataLookupTransport {
    var calls: [URLRequest] = []
    var status = 200
    func send(_ request: URLRequest) -> MetadataHTTPResponse {
        calls.append(request)
        return MetadataHTTPResponse(data: Data((status == 200 ? #"{"explanation":"An album about departures and returning home.","model":"gpt-6-astra","effort":"medium"}"# : #"{"error":"codex_limit"}"#).utf8), status: status, contentType: "application/json")
    }
    func fail() { status = 429 }
}
final class AlbumInterpretationTests: XCTestCase {
    private func album(_ text: String = "I return home.") -> AlbumInterpretationInput {
        .init(title: "Journeys", artist: "The Travellers", tracks: [
            .init(context: .init(title: "Departure", artist: "The Travellers", album: "Journeys", styles: ["Indie Rock"], moods: ["sad"]), lyrics: text, genre: "Rock"),
            .init(context: .init(title: "Home", artist: "Guest", album: "Journeys", moods: ["relaxed"]), lyrics: "", genre: "Ambient")
        ])
    }
    func testWholeAlbumRequestCacheInvalidationAndFailedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = AlbumHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "fixture")
        let cache = MetadataLookupCache(directory: root)
        let client = AlbumInterpretationClient(connection: connection, cache: cache, transport: http)
        let first = try await client.interpret(album(), language: "es", offline: false)
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].url?.path, "/v1/albums/interpret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["effort"] as? String, "medium")
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(body["album"]))
        XCTAssertEqual(try JSONDecoder().decode(AlbumInterpretationInput.self, from: data), album())
        XCTAssertEqual(album().missingLyrics, 1)
        let reopened = AlbumInterpretationClient(connection: connection, cache: cache, transport: http)
        let saved = try await reopened.interpret(album(), language: "es", offline: true)
        XCTAssertEqual(saved, first)
        var changed = album(); changed.tracks.removeLast()
        var tags = album(); tags.tracks[0] = .init(context: .init(title: "Departure", moods: ["happy"]), lyrics: "I return home.")
        for value in [album("Different words"), changed, tags] {
            do { _ = try await reopened.interpret(value, language: "es", offline: true); XCTFail("Changed album must not reuse cached meaning") }
            catch MetadataLookupError.notCached { }
        }
        await http.fail()
        do { _ = try await client.interpret(album(), language: "es", offline: false, refresh: true); XCTFail() }
        catch LyricsInterpretationError.service { }
        let preserved = try await reopened.interpret(album(), language: "es", offline: true)
        XCTAssertEqual(preserved, first)
    }
    func testRejectsOversizedAndEmptyCorporaBeforeNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = AlbumHTTP(), client = AlbumInterpretationClient(connection: try .init(endpoint: "http://localhost:8089", token: ""), cache: .init(directory: root), transport: http)
        for value in [album(""), album(String(repeating: "a", count: 65537)), .init(title: "X", artist: "Y", tracks: [])] {
            do { _ = try await client.interpret(value, language: "es", offline: false); XCTFail() }
            catch MetadataLookupError.invalidSearch { }
        }
        let calls = await http.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testPreviousAlbumCacheIsIgnoredAndMediumIsGeneratedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = AlbumHTTP(), connection = try MetadataProxyConnection(endpoint: "http://localhost:8089", token: "")
        let cache = MetadataLookupCache(directory: root)
        struct Legacy: Encodable { let album: AlbumInterpretationInput; let language = "es"; var effort: String? }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(Legacy(album: album()))).map { String(format: "%02x", $0) }.joined()
        let key = "codex-album-v1:gpt-6-astra:xhigh:\(connection.endpoint.absoluteString):\(digest)"
        let legacy = Data(#"{"explanation":"Saved album reading.","model":"gpt-6-astra","effort":"xhigh"}"#.utf8)
        try await cache.store(legacy, key: key, status: 200)
        let previousDigest = SHA256.hash(data: try encoder.encode(Legacy(album: album(), effort: "medium"))).map { String(format: "%02x", $0) }.joined()
        let previousKey = "codex-album-v1:gpt-6-astra:medium:\(connection.endpoint.absoluteString):\(previousDigest)"
        let previous = Data(#"{"explanation":"Previous medium interpretation.","model":"gpt-6-astra","effort":"medium"}"#.utf8)
        try await cache.store(previous, key: previousKey, status: 200)
        let client = AlbumInterpretationClient(connection: connection, cache: cache, transport: http)
        do { _ = try await client.interpret(album(), language: "es", offline: true); XCTFail("Previous album reading must not be shown after the reset") }
        catch MetadataLookupError.notCached { }
        let updated = try await client.interpret(album(), language: "es", offline: false)
        XCTAssertEqual(updated.effort, "medium")
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(try XCTUnwrap(calls.first).httpBody)) as? [String: Any])
        XCTAssertEqual(body["effort"] as? String, "medium")
        XCTAssertNil(body["refresh"])
        let reopened = AlbumInterpretationClient(connection: connection, cache: .init(directory: root), transport: http)
        let preferred = try await reopened.interpret(album(), language: "es", offline: true)
        XCTAssertEqual(preferred, updated)
        let oldEntry = try await cache.read(key: key)
        XCTAssertEqual(oldEntry?.data, legacy)
    }
}
