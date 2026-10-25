import Foundation
import XCTest
@testable import SonoraCore

private actor LookupHTTPFixture: MetadataLookupTransport {
    var requests: [URLRequest] = []
    var response: MetadataHTTPResponse
    var fail = false
    init(_ data: Data, status: Int = 200) { response = MetadataHTTPResponse(data: data, status: status, contentType: "application/json") }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        requests.append(request)
        if fail { throw URLError(.notConnectedToInternet) }
        return response
    }
    func stop() { fail = true }
    func rejectAuthorization() { response = MetadataHTTPResponse(data: Data(), status: 401, contentType: "application/json") }
    func markNotFound() { response = MetadataHTTPResponse(data: Data(), status: 404, contentType: "application/json") }
}

final class MetadataLookupTests: XCTestCase {
    private let recordings = Data(#"{"provider":"musicbrainz","sources":["https://musicbrainz.org/ws/2/recording"],"cache":"miss","fetched_at":1700000000,"data":[{"id":"11111111-1111-4111-8111-111111111111","title":"Fixture","artist":"Artist","duration_ms":123000,"disambiguation":"studio","score":99,"releases":[{"id":"22222222-2222-4222-8222-222222222222","title":"Album","date":"2020-01-02","country":"ES","disambiguation":null,"artwork_path":"/v1/artwork/22222222-2222-4222-8222-222222222222"}],"genres":["rock"]}]}"#.utf8)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConnectionRejectsEmbeddedCredentialsAndInsecurePublicEndpoints() throws {
        for value in ["https://user:password@example.com", "https://example.com?token=secret", "https://", "http://example.com", "http://0.0.0.0:8089", "https://0.0.0.0:8089", "https://example.com:70000", "http://10.example.0.1.2", "http://10..0.1.2", "file:///tmp/cache", "invalid"] {
            XCTAssertThrowsError(try MetadataProxyConnection(endpoint: value, token: "fixture-token"), value)
        }
        for value in ["https://music.example.com/sonora", "http://127.0.0.1:8089", "http://192.168.1.23:8089", "http://mac.local:8089", "http://100.64.0.2:8089"] {
            XCTAssertNoThrow(try MetadataProxyConnection(endpoint: value, token: "fixture-token"), value)
        }
    }

    func testLyricsAndArtworkRemainAvailableAfterClientRecreationOffline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let lyrics = Data(#"{"sources":[],"data":{"id":3,"trackName":"Fixture","artistName":"Artist","albumName":"Album","duration":123,"instrumental":false,"plainLyrics":"Verse","syncedLyrics":"[00:01]Verse"}}"#.utf8)
        let connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture")
        let transport = LookupHTTPFixture(lyrics)
        let client = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
        _ = try await client.lyrics(title: "Fixture", artist: "Artist", album: "Album", duration: 123, offline: false)
        let image = Data([0xff, 0xd8, 0xff, 0xd9]), artworkTransport = LookupHTTPFixture(Data([0xff, 0xd8, 0xff, 0xd9]))
        let images = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: artworkTransport)
        let id = "22222222-2222-4222-8222-222222222222"
        _ = try await images.artwork(id, offline: false)
        await transport.stop(); await artworkTransport.stop()
        let reopened = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
        let saved = try await reopened.lyrics(title: "Fixture", artist: "Artist", album: "Album", duration: 123, offline: true)
        let cover = try await reopened.artwork(id, offline: true)
        XCTAssertEqual(saved.value.syncedLyrics, "[00:01]Verse"); XCTAssertEqual(saved.value.plainLyrics, "Verse")
        XCTAssertEqual(cover.value, image); XCTAssertTrue(saved.isCached); XCTAssertTrue(cover.isCached)
        let calls = await transport.requests; XCTAssertEqual(calls.count, 1)
    }

    func testIdentificationSendsOnlyFingerprintAndDurationAndCachesDistinctRequests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let response = Data(#"{"sources":[],"data":{"status":"ok","results":[{"score":0.9,"recordings":[{"id":"11111111-1111-4111-8111-111111111111"}]},{"score":0.7,"recordings":[{"id":"11111111-1111-4111-8111-111111111111"}]}]}}"#.utf8)
        let transport = LookupHTTPFixture(response)
        let connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "private-test-token")
        let client = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
        let live = try await client.identify(fingerprint: "AQABAAfixture", duration: 200, offline: false)
        XCTAssertEqual(live.value.recordingIDs, ["11111111-1111-4111-8111-111111111111"])
        let requests = await transport.requests, request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/identify")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(Set(body?.keys.map { $0 } ?? []), ["fingerprint", "duration"])
        XCTAssertEqual(body?["fingerprint"] as? String, "AQABAAfixture"); XCTAssertEqual(body?["duration"] as? Int, 200)
        await transport.stop()
        let offline = try await client.identify(fingerprint: "AQABAAfixture", duration: 200, offline: true)
        XCTAssertTrue(offline.isCached)
        do { _ = try await client.identify(fingerprint: "AQABAAother", duration: 200, offline: true); XCTFail("Distinct audio must not reuse another fingerprint's result") }
        catch MetadataLookupError.notCached { }
        let calls = await transport.requests; XCTAssertEqual(calls.count, 1)
    }

    func testAuthenticatedSearchCachesResultsAndOfflineReuseSurvivesRecreation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LookupHTTPFixture(recordings)
        let connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089/sonora", token: "private-test-token")
        let query = MetadataSearch(title: "Fixture & friends", artist: "Artist", album: "Album")
        let client = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
        let live = try await client.search(query, offline: false)
        XCTAssertEqual(live.value.first?.title, "Fixture")
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.value(forHTTPHeaderField: "Authorization"), "Bearer private-test-token")
        XCTAssertEqual(calls.first?.url?.path, "/sonora/v1/recordings")
        XCTAssertFalse(calls.first?.url?.absoluteString.contains("private-test-token") ?? true)
        let items = URLComponents(url: try XCTUnwrap(calls.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "title" }?.value, "Fixture & friends")
        await transport.stop()
        let reopened = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
        let saved = try await reopened.search(query, offline: true)
        XCTAssertEqual(saved.value.first?.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertTrue(saved.isCached)
        let after = await transport.requests; XCTAssertEqual(after.count, 1)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("private-test-token".utf8)))
        }
    }

    func testOfflineMissNeverContactsServerAndOnlineFailureCanUseStaleCache() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LookupHTTPFixture(recordings)
        let client = MetadataLookupClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture"), cache: MetadataLookupCache(directory: root), transport: transport)
        let query = MetadataSearch(title: "Fixture", artist: "Artist", album: "Album")
        do { _ = try await client.search(query, offline: true); XCTFail("No offline result exists") }
        catch MetadataLookupError.notCached { }
        let empty = await transport.requests; XCTAssertTrue(empty.isEmpty)
        _ = try await client.search(query, offline: false)
        await transport.stop()
        let fallback = try await client.search(query, offline: false, refresh: true)
        XCTAssertTrue(fallback.isCached); XCTAssertNotNil(fallback.warning)
        XCTAssertEqual(fallback.value.first?.title, "Fixture")
    }
    func testFreshNotFoundIsNotHiddenByNegativeCacheWriteFailure() async throws {
        for hasOldSuccess in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let transport = LookupHTTPFixture(recordings)
            let connection = try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture")
            let query = MetadataSearch(title: "Fixture", artist: "Artist", album: "Album")
            if hasOldSuccess {
                let initial = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root), transport: transport)
                _ = try await initial.search(query, offline: false)
            }
            await transport.markNotFound()
            let client = MetadataLookupClient(connection: connection, cache: MetadataLookupCache(directory: root, maxBytes: 1), transport: transport)
            do {
                _ = try await client.search(query, offline: false, refresh: true)
                XCTFail("A fresh 404 must not turn into an obsolete successful result")
            } catch MetadataLookupError.notFound { }
        }
    }

    func testAuthenticationErrorsStayVisibleAndDoNotMasqueradeAsOfflineSuccess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = LookupHTTPFixture(Data(), status: 401)
        let client = MetadataLookupClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "bad-token"), cache: MetadataLookupCache(directory: root), transport: transport)
        do { _ = try await client.search(MetadataSearch(title: "Fixture"), offline: false); XCTFail("Token is invalid") }
        catch MetadataLookupError.unauthorized { }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)

        let good = LookupHTTPFixture(recordings)
        let withCache = MetadataLookupClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "changed-token"), cache: MetadataLookupCache(directory: root), transport: good)
        _ = try await withCache.search(MetadataSearch(title: "Fixture"), offline: false)
        await good.rejectAuthorization()
        do { _ = try await withCache.search(MetadataSearch(title: "Fixture"), offline: false, refresh: true); XCTFail("A saved result must not hide an explicit authentication failure") }
        catch MetadataLookupError.unauthorized { }
    }

    func testCancelledProducerCannotRepopulateAClearedCache() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = MetadataLookupCache(directory: root)
        let producer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.storeUnlessCancelled(Data("obsolete".utf8), key: "image", status: 200)
        }
        do { try await producer.value; XCTFail("A cancelled producer must not write") }
        catch is CancellationError { }
        let size = try await cache.size(); XCTAssertEqual(size, 0)
        try await cache.storeUnlessCancelled(Data("fresh".utf8), key: "image", status: 200)
        let entry = try await cache.read(key: "image"); XCTAssertEqual(entry?.data, Data("fresh".utf8))
    }
    func testCacheEvictsOldestAndPreservesUnrelatedFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("keep.txt"); try Data("Keep".utf8).write(to: unrelated)
        let cache = MetadataLookupCache(directory: root, maxBytes: 1500, maxEntries: 2)
        try await cache.store(Data(repeating: 65, count: 800), key: "first", status: 200)
        try await cache.store(Data(repeating: 66, count: 800), key: "second", status: 200)
        let removed = try await cache.read(key: "first"); XCTAssertNil(removed)
        let saved = try await cache.read(key: "second"); XCTAssertEqual(saved?.data.count, 800)
        try await cache.clear()
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("Keep".utf8))
    }

    func testChosenReleaseMapsTrackAndDiscWithoutReplacingExistingValuesByDefault() throws {
        let envelope = try JSONDecoder().decode(MetadataProxyEnvelope<[MetadataRecording]>.self, from: recordings)
        let recording = try XCTUnwrap(envelope.data.first)
        let release = try JSONDecoder().decode(MetadataRelease.self, from: Data(#"{"id":"22222222-2222-4222-8222-222222222222","title":"Album","date":"2020-01-02","artist-credit":[{"name":"Album Artist"}],"media":[{"position":1,"track-count":2,"tracks":[{"position":2,"number":"2","title":"Release title","recording":{"id":"11111111-1111-4111-8111-111111111111"}}]}]}"#.utf8))
        let proposal = release.suggestedValues(for: recording)
        XCTAssertEqual(proposal[.title], "Release title")
        XCTAssertEqual(proposal[.albumArtist], "Album Artist")
        XCTAssertEqual(proposal[.trackNumber], "2"); XCTAssertEqual(proposal[.trackTotal], "2")
        XCTAssertEqual(proposal[.discNumber], "1"); XCTAssertEqual(proposal[.discTotal], "1")
        let changes = MetadataSuggestions.changes(proposed: proposal, current: [.title: "Manual title", .artist: ""], onlyMissing: true)
        XCTAssertNil(changes[.title]); XCTAssertEqual(changes[.artist], "Artist")
        XCTAssertEqual(MetadataSuggestions.changes(proposed: proposal, current: [.title: "Manual title"], onlyMissing: false)[.title], "Release title")
    }
}
