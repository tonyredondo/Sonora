import CryptoKit
import Foundation
import XCTest
@testable import SonoraCore

private actor LyricsFallbackFixture: MetadataLookupTransport {
    var paths: [String] = []
    let catalogStatus: Int
    let plain: String?
    let timed: String?
    let empty: Bool
    let wrongAudio: Bool
    let wordTimes: Bool
    let wrongWords: Bool
    init(catalogStatus: Int = 404, plain: String? = nil, timed: String? = nil, empty: Bool = false, wrongAudio: Bool = false, wordTimes: Bool = false, wrongWords: Bool = false) {
        self.catalogStatus = catalogStatus; self.plain = plain; self.timed = timed; self.empty = empty; self.wrongAudio = wrongAudio
        self.wordTimes = wordTimes; self.wrongWords = wrongWords
    }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let path = request.url!.path; paths.append(path)
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        var value: [String: Any]
        if path == "/v1/lyrics" {
            value = ["id":1,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":2,"instrumental":false,
                     "plainLyrics":plain as Any? ?? NSNull(),"syncedLyrics":timed as Any? ?? NSNull()]
            return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["sources":[],"data":value]), status: catalogStatus, contentType: "application/json")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("audio.wav"))
        if path == "/v1/lyrics/align" {
            XCTAssertTrue(body.contains("Hello\nAgain"))
            value = ["plain_lyrics":"Hello\nAgain","synced_lyrics":"[00:00.10]Hello\n[00:01.10]Again","duration":2,
                     "audio_sha256":hash(pcmFixture()),"text_sha256":hash(Data("Hello\nAgain".utf8))]
        } else {
            XCTAssertEqual(path, "/v1/lyrics/transcribe")
            XCTAssertFalse(body.contains("name=\"text\""), "Transcription has no known lyrics to upload")
            value = ["plain_lyrics":empty ? "" : "Hello\nAgain","synced_lyrics":empty ? "" : "[00:00.10]Hello\n[00:01.10]Again",
                     "duration":2,"audio_sha256":hash(wrongAudio ? Data([9]) : pcmFixture()),"model_id":"scribe_v2"]
            if wordTimes {
                value["words"] = [["text": wrongWords ? "Different" : "Hello", "start":0.1,"end":0.5],
                                  ["text":"Again","start":1.1,"end":1.5]]
            }
        }
        return MetadataHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["sources":[],"data":value]), status: 200, contentType: "application/json")
    }
    func requests() -> [String] { paths }
}

final class LyricsTranscriptionTests: XCTestCase {
    func testRepairedPlainLyricsRetainTheirAttributionAfterSynchronization() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at:root) }
        let http = LyricsFallbackFixture()
        let value = try await client(root,http).synchronize(query:MetadataSearch(title:""),duration:2,lyrics:LyricsDocument.aiRepairMarker + "\nHello\nAgain",offline:false) { pcmFixture() }
        XCTAssertTrue(LyricsDocument(text:value.value.text).isAIRepaired)
    }
    func testExplicitRepairAnalysisReusesTranscriptionAcrossClientsAndMissingLyricsFallback() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture(wordTimes:true)
        let first = try await client(root,http).transcription(duration:2,offline:false) { pcmFixture() }
        XCTAssertEqual(first.value.words?.map(\.text),["Hello","Again"])
        XCTAssertEqual(first.value.words?.last?.start,1.1)
        let offline = try await client(root,http).transcription(duration:2,offline:true) { pcmFixture() }
        XCTAssertTrue(offline.isCached)
        XCTAssertEqual(offline.value,first.value)
        let previousFlow = try await client(root,http).synchronize(query:MetadataSearch(title:""),duration:2,lyrics:"",offline:false) { pcmFixture() }
        XCTAssertTrue(previousFlow.isCached)
        let paths = await http.requests(); XCTAssertEqual(paths,["/v1/lyrics/transcribe"])
    }
    func testLegacyCachedTranscriptionCanBeUsedWithoutAnotherPaidRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture()
        _ = try await client(root,http).synchronize(query:MetadataSearch(title:""),duration:2,lyrics:"",offline:false) { pcmFixture() }
        let repair = try await client(root,http).transcription(duration:2,offline:true) { pcmFixture() }
        XCTAssertTrue(repair.isCached); XCTAssertNil(repair.value.words)
        XCTAssertEqual(repair.value.plainText,"Hello\nAgain")
        let paths = await http.requests(); XCTAssertEqual(paths,["/v1/lyrics/transcribe"])
    }
    func testInconsistentWordTimesCannotEnterTheRepairCache() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture(wordTimes:true,wrongWords:true)
        do { _ = try await client(root,http).transcription(duration:2,offline:false) { pcmFixture() }; XCTFail("Words must match the transcript") }
        catch { XCTAssertEqual(error as? LyricsSynchronizationError,.invalidAlignment) }
        do { _ = try await client(root,http).transcription(duration:2,offline:true) { pcmFixture() }; XCTFail("Rejected words must not be cached") }
        catch { XCTAssertEqual(error as? MetadataLookupError,.notCached) }
    }
    private let query = MetadataSearch(title: "Song", artist: "Artist", album: "Album")
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func client(_ root: URL, _ http: LyricsFallbackFixture, endpoint: String = "http://127.0.0.1:8089") throws -> LyricsSynchronizationClient {
        LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: endpoint, token: "fixture"), cache: MetadataLookupCache(directory: root), transport: http)
    }
    func testCatalogPlainLyricsAreAlignedAndReusedOfflineWithoutEmbeddedText() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture(catalogStatus: 200, plain: "Hello\nAgain")
        let first = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        XCTAssertEqual(first.value.source, .elevenlabs)
        let saved = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: true) { pcmFixture() }
        XCTAssertTrue(saved.isCached); XCTAssertEqual(saved.value.text, first.value.text)
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics", "/v1/lyrics/align"])
    }
    func testMissingLyricsAreTranscribedOnceWithPersistentAttributionAndOfflineReuse() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture()
        let first = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        XCTAssertEqual(first.value.source.rawValue, "elevenlabsTranscription")
        XCTAssertTrue(first.value.text.contains("[by:Sonora AI transcription - ElevenLabs]"))
        XCTAssertEqual(LyricsDocument(text: first.value.text).lines.map(\.text), ["Hello", "Again"])
        for offline in [false, true] {
            let saved = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: offline) { pcmFixture() }
            XCTAssertTrue(saved.isCached); XCTAssertEqual(saved.value.text, first.value.text)
        }
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics", "/v1/lyrics/transcribe"])
    }
    func testTimedCatalogHitIsCachedAndNeverPreparesAudio() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture(catalogStatus: 200, timed: "[00:00.10]Hello\n[00:01.10]Again")
        for offline in [false, true] {
            let found = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: offline) { XCTFail("Catalog hits do not decode audio"); return pcmFixture() }
            XCTAssertEqual(found.value.source, .lrclib)
        }
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics"])
    }
    func testEmptyTranscriptIsCachedInsteadOfStartingAnotherPaidCall() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture(empty: true)
        for offline in [false, false, true] {
            do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: offline) { pcmFixture() }; XCTFail("No words must be reported explicitly") }
            catch { XCTAssertTrue(error is LyricsSynchronizationError) }
        }
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics", "/v1/lyrics/transcribe"])
    }
    func testAudioAndEndpointSeparateTranscriptionCachesButMetadataDoesNot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LyricsFallbackFixture()
        let first = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { pcmFixture() }
        let renamed = try await client(root, http).synchronize(query: MetadataSearch(title: "Renamed"), duration: 2, lyrics: "", offline: true) { pcmFixture() }
        XCTAssertEqual(renamed.value, first.value)
        do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: true) { pcmFixture(marker: 1) }; XCTFail("Different audio cannot reuse timings") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
        do { _ = try await client(root, http, endpoint: "http://127.0.0.1:8090").synchronize(query: query, duration: 2, lyrics: "", offline: true) { pcmFixture() }; XCTFail("Different endpoints have separate caches") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
    }
    func testCatalogErrorsAndCancellationNeverStartTranscription() async throws {
        for status in [401, 503] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let http = LyricsFallbackFixture(catalogStatus: status)
            do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { XCTFail("No paid fallback on an outage"); return pcmFixture() }; XCTFail("Must report the catalog error") }
            catch { XCTAssertEqual(error as? MetadataLookupError, status == 401 ? .unauthorized : .unavailable) }
            let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics"])
        }
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }; let http = LyricsFallbackFixture()
        do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { throw CancellationError() }; XCTFail("Cancelled decoding cannot upload") }
        catch { XCTAssertTrue(error is CancellationError) }
        let paths = await http.requests(); XCTAssertEqual(paths, ["/v1/lyrics"])
    }
    func testWrongAudioTranscriptIsRejectedBeforeCaching() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }; let http = LyricsFallbackFixture(wrongAudio: true)
        do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: false) { pcmFixture() }; XCTFail("Unrelated audio cannot be accepted") }
        catch { XCTAssertTrue(error is LyricsSynchronizationError) }
        do { _ = try await client(root, http).synchronize(query: query, duration: 2, lyrics: "", offline: true) { pcmFixture() }; XCTFail("Invalid replies must not be cached") }
        catch { XCTAssertEqual(error as? MetadataLookupError, .notCached) }
    }
}
