import CryptoKit
import Foundation
import XCTest
@testable import SonoraCore

func pcmFixture(marker: UInt8 = 0) -> Data {
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    append(UInt32(64036)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(64000))
    data.append(Data(repeating: marker, count: 64000)); return data
}

private actor LyricsHTTPFixture: MetadataLookupTransport {
    var paths: [String] = []
    let catalog: Int
    let catalogText: String?
    let audio: Data
    let text: String
    let mismatchedAudio: Bool
    init(catalog: Int = 404, catalogText: String? = nil, audio: Data = pcmFixture(), text: String = "Hello\nAgain", mismatchedAudio: Bool = false) {
        self.catalog = catalog; self.catalogText = catalogText; self.audio = audio; self.text = text; self.mismatchedAudio = mismatchedAudio
    }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        paths.append(request.url!.path)
        if request.url!.path == "/v1/lyrics" {
            let value: [String: Any] = ["id":1,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":2,"instrumental":false,"plainLyrics":text,"syncedLyrics":catalogText as Any? ?? NSNull()]
            return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["sources":[],"data":value]), status: catalog, contentType: "application/json")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains(text))
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let value: [String: Any] = ["plain_lyrics":text,"synced_lyrics":"[00:00.10]Hello\n[00:01.10]Again","duration":2,"audio_sha256":hash(mismatchedAudio ? Data([9]) : audio),"text_sha256":hash(Data(text.utf8))]
        return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["sources":[],"data":value]), status: 200, contentType: "application/json")
    }
    func requests() -> [String] { paths }
}

final class LyricsSynchronizationTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private let query = MetadataSearch(title: "Song", artist: "Artist", album: "Album")
    func testCatalogHitDoesNotPrepareOrUploadAudio() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture(catalog: 200, catalogText: "[00:00.10]Hello\n[00:01.10]Again")
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        let result = try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) {
            XCTFail("Catalog hits must not prepare audio"); throw CancellationError()
        }
        XCTAssertEqual(result.value.source, .lrclib)
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics"])
    }
    func testFallbackPreservesTextAndReusesOfflineCacheAfterRecreation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture(); let cache = MetadataLookupCache(directory: root)
        let connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture")
        let client = LyricsSynchronizationClient(connection: connection, cache: cache, transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        let first = try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) { pcmFixture() }
        XCTAssertEqual(first.value.source, .elevenlabs)
        let reopened = LyricsSynchronizationClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        let next = try await reopened.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: true) { pcmFixture() }
        XCTAssertTrue(next.isCached); XCTAssertEqual(next.value.text, first.value.text)
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics", "/v1/lyrics/align"])
    }
    func testCatalogOutageDoesNotTriggerPaidFallback() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture(catalog: 503)
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        do { _ = try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) { XCTFail("No paid fallback on outage"); throw CancellationError() }; XCTFail("Must report outage") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .unavailable) }
    }
    func testCatalogRejectsDifferentEditionIncompleteTimingAndOutOfRangeLines() {
        for text in ["[00:00]Wrong\n[00:01]Again", "[00:00]Hello\nAgain", "[00:00]Hello\n[00:03]Again", "[00:02]Hello\n[00:01]Again"] {
            XCTAssertNil(LyricsSynchronizationResult.catalog(text: text, existing: "Hello\nAgain", duration: 2))
        }
    }
    func testDifferentAudioOrTextCannotReusePriorAlignmentOffline() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture()
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        _ = try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) { pcmFixture() }
        for (text, audio) in [("Hello\nAgain!", pcmFixture()), ("Hello\nAgain", pcmFixture(marker: 1))] {
            do { _ = try await client.synchronize(query: query, duration: 2, lyrics: text, offline: true) { audio }; XCTFail("Different inputs must not reuse timings") }
            catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
        }
        let paths = await http.requests(); XCTAssertEqual(paths.count, 2)
    }
    func testMismatchedAudioResponseIsRejectedBeforeCaching() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture(mismatchedAudio: true)
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        do { _ = try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) { pcmFixture() }; XCTFail("Wrong audio must fail") }
        catch { XCTAssertTrue(error is LyricsSynchronizationError) }
    }

    func testTimedRepairedLyricsAlignCurrentWordsAndReuseTheSameCache() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture(catalog: 200, catalogText: "[00:00]Wrong edition")
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        let text = LyricsDocument.aiTranscriptionMarker + "\n" + LyricsDocument.aiRepairMarker + "\n[00:00.90]Hello\n[00:01.90]Again"
        let first = try await client.synchronize(query: query, duration: 2, lyrics: text, offline: false) { pcmFixture() }
        XCTAssertEqual(first.value.source, .elevenlabs)
        XCTAssertEqual(LyricsDocument(text: first.value.text).lines.map(\.time), [0.1, 1.1])
        XCTAssertTrue(LyricsDocument(text: first.value.text).isAITranscribed)
        XCTAssertTrue(LyricsDocument(text: first.value.text).isAIRepaired)
        let second = try await client.synchronize(query: query, duration: 2, lyrics: first.value.text, offline: true) { pcmFixture() }
        XCTAssertEqual(second.value.text, first.value.text); XCTAssertTrue(second.isCached)
        let calls = await http.requests(); XCTAssertEqual(calls, ["/v1/lyrics/align"], "Times and attribution do not change the audio/text cache identity")
        do {
            _ = try await client.synchronize(query: query, duration: 2, lyrics: "[00:00.1]Hello corrected\n[00:01.1]Again", offline: true) { pcmFixture() }
            XCTFail("A changed draft must not reuse timings for other words")
        } catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
    }

    func testCancellationWhilePreparingAudioDoesNotStartPaidRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsHTTPFixture()
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http, diagnostics: MetadataDiagnostics(directory: root.appendingPathComponent("Diagnostics")))
        let started = expectation(description: "Audio preparation started after catalog miss")
        let pending = Task { try await client.synchronize(query: query, duration: 2, lyrics: "Hello\nAgain", offline: false) {
            started.fulfill(); try await Task.sleep(nanoseconds: 10_000_000_000); return pcmFixture()
        } }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled audio cannot be uploaded") } catch is CancellationError { }
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics"])
    }

}
