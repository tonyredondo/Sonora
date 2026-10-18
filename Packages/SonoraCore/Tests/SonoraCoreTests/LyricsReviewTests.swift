import CryptoKit
import Foundation
import XCTest
@testable import SonoraCore

private actor ReviewLyricsTransport: MetadataLookupTransport {
    private var paths: [String] = []
    var catalogStatus: Int
    let catalogPlain: String?
    let plain: String
    let timed: String
    init(catalogStatus: Int = 503, catalogPlain: String? = nil, plain: String = "Hello\nAgain", timed: String = "[00:00.10]Hello\n[00:01.10]Again") {
        self.catalogStatus = catalogStatus; self.catalogPlain = catalogPlain; self.plain = plain; self.timed = timed
    }
    func setCatalogStatus(_ status: Int) { catalogStatus = status }
    func requests() -> [String] { paths }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let path = request.url!.path; paths.append(path)
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        var status = 200
        var data: [String: Any] = ["plain_lyrics": plain, "synced_lyrics": timed, "duration": 2,
                                  "audio_sha256": hash(pcmFixture()), "model_id": "scribe_v2"]
        if path == "/v1/lyrics" {
            status = catalogStatus
            data = ["id": 1, "trackName": "Song", "artistName": "Artist", "albumName": "Album", "duration": 2,
                    "instrumental": false, "plainLyrics": catalogPlain as Any? ?? NSNull(), "syncedLyrics": NSNull()]
        } else if path == "/v1/lyrics/align" {
            data["text_sha256"] = hash(Data(plain.utf8))
        } else { XCTAssertEqual(path, "/v1/lyrics/transcribe") }
        return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["data": data, "sources": []]), status: status, contentType: "application/json")
    }
}

final class LyricsReviewTests: XCTestCase {
    private let complete = MetadataSearch(title: "Song", artist: "Artist", album: "Album")
    private let incomplete = MetadataSearch(title: "Song")
    private func client(_ root: URL, _ http: ReviewLyricsTransport) throws -> LyricsSynchronizationClient {
        LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http)
    }
    func testInformationOnlyLyricsUseTranscriptionInsteadOfAlignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(), client = try client(root, http)
        let headers = "  [ar:Artist]\n[ti:Song]\n[by:Editor]\n[length:00:02]"
        let result = try await client.synchronize(query: incomplete, duration: 2, lyrics: headers, offline: false) { pcmFixture() }
        XCTAssertEqual(result.value.source, .elevenlabsTranscription)
        let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics/transcribe"])
    }
    func testCatalogInformationOnlyLyricsUseTranscriptionInsteadOfAlignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(catalogStatus: 200, catalogPlain: "[ar:Artist]\n[ti:Song]"), client = try client(root, http)
        let result = try await client.synchronize(query: complete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        XCTAssertEqual(result.value.source, .elevenlabsTranscription)
        let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics", "/v1/lyrics/transcribe"])
    }
    func testAlignmentOmitsInformationHeadersButKeepsVerseSpacing() async throws {
        for separator in ["\n", "\r\n", "\r"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let http = ReviewLyricsTransport(plain: "Hello\n\nAgain"), client = try client(root, http)
            let lyrics = ["[ar:Artist]", "Hello", "", "Again", "[by:Editor]"].joined(separator: separator)
            let result = try await client.synchronize(query: incomplete, duration: 2, lyrics: lyrics, offline: false) { pcmFixture() }
            XCTAssertEqual(result.value.text, "[00:00.10]Hello\n\n[00:01.10]Again")
            let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics/align"])
        }
    }
    func testCatalogOutageReusesCachedTranscriptionWithoutAnotherPaidRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(), client = try client(root, http)
        let first = try await client.synchronize(query: incomplete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        let cached = try await client.synchronize(query: complete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        XCTAssertEqual(cached.value, first.value); XCTAssertTrue(cached.isCached); XCTAssertNotNil(cached.warning)
        let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics/transcribe", "/v1/lyrics"])
    }
    func testCatalogOutageReusesAlignmentForStaleCatalogPlainText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(catalogStatus: 200, catalogPlain: "Hello\nAgain"), client = try client(root, http)
        let first = try await client.synchronize(query: complete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            var entry = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            if (entry["key"] as? String ?? "").contains("/v1/lyrics?") {
                entry["savedAt"] = Date(timeIntervalSinceNow: -31 * 86400)
                try PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0).write(to: file)
            }
        }
        await http.setCatalogStatus(503)
        let cached = try await client.synchronize(query: complete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        XCTAssertEqual(cached.value, first.value); XCTAssertTrue(cached.isCached); XCTAssertNotNil(cached.warning)
        let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics", "/v1/lyrics/align", "/v1/lyrics"])
    }
    func testCatalogOutageCannotReplaceKnownTextWithCachedAIText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(), client = try client(root, http)
        _ = try await client.synchronize(query: incomplete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        do { _ = try await client.synchronize(query: complete, duration: 2, lyrics: "Different lyrics", offline: false) { pcmFixture() }; XCTFail("Do not replace known lyrics or initiate paid work") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .unavailable) }
        let requests = await http.requests(); XCTAssertEqual(requests, ["/v1/lyrics/transcribe", "/v1/lyrics"])
    }
    func testAuthenticationFailureNeverFallsBackToCachedAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = ReviewLyricsTransport(catalogStatus: 401), client = try client(root, http)
        _ = try await client.synchronize(query: incomplete, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        do { _ = try await client.synchronize(query: complete, duration: 2, lyrics: "", offline: false) { XCTFail("Authentication failure must remain visible"); return pcmFixture() }; XCTFail("Expected authentication error") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .unauthorized) }
    }
    func testInconsistentOrShiftedTranscriptionIsRejectedBeforeCaching() async throws {
        for (plain, timed) in [("", "[00:00.10]Hello"), ("Hello", "[offset:-3000]\n[00:00.10]Hello")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let http = ReviewLyricsTransport(plain: plain, timed: timed), client = try client(root, http)
            do { _ = try await client.synchronize(query: incomplete, duration: 2, lyrics: "", offline: false) { pcmFixture() }; XCTFail("Malformed transcription cannot be used") }
            catch { XCTAssertTrue(error is LyricsSynchronizationError) }
            do { _ = try await client.synchronize(query: incomplete, duration: 2, lyrics: "", offline: true) { pcmFixture() }; XCTFail("Malformed transcription cannot enter the cache") }
            catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
        }
    }
}
