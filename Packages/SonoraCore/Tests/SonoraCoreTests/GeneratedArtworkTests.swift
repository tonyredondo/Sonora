import Foundation
import XCTest
@testable import SonoraCore

private actor ArtworkHTTP: MetadataLookupTransport {
    private(set) var calls: [URLRequest] = []
    var response: MetadataHTTPResponse
    init(_ response: MetadataHTTPResponse) { self.response = response }
    func respond(_ response: MetadataHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) -> MetadataHTTPResponse { calls.append(request); return response }
}
final class GeneratedArtworkTests: XCTestCase {
    private var input: GeneratedArtworkInput { .init(title: "Quiet Horizon", artist: "Synthetic Artist", album: "First Light", albumDescription: "A record about beginnings.", genre: "Ambient", styles: ["Electronic"], moods: ["relaxed"]) }
    func testJobSubmissionAndRecoveryUseStableAuthenticatedRoutes() async throws {
        let id = String(repeating: "a", count: 64)
        let http = ArtworkHTTP(.init(data: Data("{\"id\":\"\(id)\",\"state\":\"queued\"}".utf8), status: 202, contentType: "application/json"))
        let client = GeneratedArtworkClient(connection: try .init(endpoint: "http://localhost:8089", token: "fixture"), transport: http)
        let submitted = try await client.submit(input, offline: false)
        XCTAssertEqual(submitted.id, id); XCTAssertEqual(submitted.state, .queued)
        await http.respond(.init(data: Data("{\"id\":\"\(id)\",\"state\":\"completed\"}".utf8), status: 200, contentType: "application/json"))
        let restored = try await client.job(id, offline: false)
        XCTAssertEqual(restored.state, .completed)
        let requests = await http.calls
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/artwork/jobs", "/v1/artwork/jobs/\(id)"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
        XCTAssertEqual(try JSONDecoder().decode(GeneratedArtworkInput.self, from: XCTUnwrap(requests.first?.httpBody)), input)
        XCTAssertNil(requests.first?.url?.query)
        _ = try await client.submit(input, retryFailed: true, offline: false)
        let retryRequest = await http.calls.last
        XCTAssertEqual(retryRequest?.url?.query, "retry_failed=true")
    }
    func testJobRecoveryRejectsOfflineInvalidAndMismatchedIdentifiers() async throws {
        let id = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let http = ArtworkHTTP(.init(data: Data("{\"id\":\"\(other)\",\"state\":\"running\"}".utf8), status: 200, contentType: "application/json"))
        let client = GeneratedArtworkClient(connection: try .init(endpoint: "http://localhost:8089", token: ""), transport: http)
        do { _ = try await client.submit(input, offline: true); XCTFail() } catch MetadataLookupError.notCached { }
        do { _ = try await client.job(id, offline: true); XCTFail() } catch MetadataLookupError.notCached { }
        do { _ = try await client.image(id, offline: true); XCTFail() } catch MetadataLookupError.notCached { }
        do { _ = try await client.job("../private", offline: false); XCTFail() } catch MetadataLookupError.invalidSearch { }
        let offlineCalls = await http.calls; XCTAssertTrue(offlineCalls.isEmpty)
        do { _ = try await client.job(id, offline: false); XCTFail() } catch MetadataLookupError.invalidResponse { }
    }
    func testJobFailuresDistinguishOldServerMissingWorkAndExpiredImage() async throws {
        let id = String(repeating: "a", count: 64)
        let http = ArtworkHTTP(.init(data: Data(), status: 405, contentType: nil))
        let client = GeneratedArtworkClient(connection: try .init(endpoint: "http://localhost:8089", token: ""), transport: http)
        do { _ = try await client.submit(input, offline: false); XCTFail() } catch GeneratedArtworkIssue.serverUpdateRequired { }
        await http.respond(.init(data: Data(), status: 404, contentType: nil))
        do { _ = try await client.job(id, offline: false); XCTFail() } catch MetadataLookupError.notFound { }
        await http.respond(.init(data: Data(), status: 409, contentType: nil))
        do { _ = try await client.image(id, offline: false); XCTFail() } catch MetadataLookupError.notFound { }
        await http.respond(.init(data: Data(), status: 401, contentType: nil))
        do { _ = try await client.job(id, offline: false); XCTFail() } catch MetadataLookupError.unauthorized { }
    }
    func testNativeImageRequestSendsVisualContextWithoutLocalFiles() async throws {
        let png = Data([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,4,0,0,0,181,28,12,2,0,0,0,11,73,68,65,84,120,218,99,252,255,31,0,3,3,2,0,239,151,218,44,0,0,0,0,73,69,78,68,174,66,96,130])
        let http = ArtworkHTTP(.init(data: png, status: 200, contentType: "image/png"))
        let client = GeneratedArtworkClient(connection: try .init(endpoint: "http://localhost:8089", token: "fixture"), transport: http)
        let image = try await client.generate(input, offline: false)
        XCTAssertEqual(image, png)
        let calls = await http.calls, request = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(request.url?.path, "/v1/artwork/generate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(try JSONDecoder().decode(GeneratedArtworkInput.self, from: XCTUnwrap(request.httpBody)), input)
        for field in ["lyrics", "file", "path", "token"] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(json[field])
        }
    }
    func testOfflineInvalidAndNonImageResponsesNeverSucceed() async throws {
        let http = ArtworkHTTP(.init(data: Data("not an image".utf8), status: 200, contentType: "image/png"))
        let client = GeneratedArtworkClient(connection: try .init(endpoint: "http://localhost:8089", token: ""), transport: http)
        do { _ = try await client.generate(input, offline: true); XCTFail() } catch MetadataLookupError.notCached { }
        let invalid = GeneratedArtworkInput(title: "", artist: "", album: "", albumDescription: "")
        do { _ = try await client.generate(invalid, offline: false); XCTFail() } catch MetadataLookupError.invalidSearch { }
        let before = await http.calls; XCTAssertTrue(before.isEmpty)
        do { _ = try await client.generate(input, offline: false); XCTFail() } catch GeneratedArtworkIssue.invalidImage { }
    }
    func testArtworkIdentityIncludesAlbumMeaningAndSongTags() {
        let variations = [GeneratedArtworkInput(title: "Other", artist: input.artist, album: input.album, albumDescription: input.albumDescription),
                          .init(title: input.title, artist: input.artist, album: input.album, albumDescription: "Other story"),
                          .init(title: input.title, artist: input.artist, album: input.album, albumDescription: input.albumDescription, moods: ["sad"])]
        XCTAssertEqual(Set(variations.map(\.cacheIdentity)).count, variations.count)
        XCTAssertTrue(variations.allSatisfy { $0.cacheIdentity != input.cacheIdentity })
    }
}

extension GeneratedArtworkTests {
    func testHeaderExtensionUsesSeparateDurableRoutesAndAcknowledgesOnlyItsDownloadedHash() async throws {
        let id=String(repeating: "a",count:64)
        let http=ArtworkHTTP(.init(data:Data("{\"id\":\"\(id)\",\"state\":\"queued\"}".utf8),status:202,contentType:"application/json"))
        let client=GeneratedArtworkClient(connection:try .init(endpoint:"http://localhost:8089",token:"fixture"),transport:http,kind:.headerExtension)
        let original=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQMgn7D8IMMAYANAwGbdbSwQUAAAAASUVORK5CYII=")!
        _ = try await client.submitExtension(original,offline:false)
        var calls=await http.calls
        XCTAssertEqual(calls[0].url?.path,"/v1/artwork/expansions/jobs")
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(calls[0].httpBody)) as? [String:String])
        XCTAssertEqual(json,["image":original.base64EncodedString(),"aspect":"2:3"])
        let image=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEUlEQVR4nGMQMgn7D8IMGAwAeWsJo1S5O6UAAAAASUVORK5CYII=")!
        await http.respond(.init(data:image,status:200,contentType:"image/png"))
        let downloaded = try await client.image(id,offline:false)
        XCTAssertEqual(downloaded,image)
        await http.respond(.init(data:Data("{}".utf8),status:200,contentType:"application/json"))
        try await client.acknowledge(id,sha256:String(repeating:"b",count:64),offline:false)
        calls=await http.calls
        XCTAssertEqual(calls.map{ $0.url?.path },["/v1/artwork/expansions/jobs","/v1/artwork/expansions/jobs/\(id)/image","/v1/artwork/expansions/jobs/\(id)/ack"])
        XCTAssertTrue(calls.allSatisfy{ $0.value(forHTTPHeaderField:"Authorization")=="Bearer fixture" })
        XCTAssertFalse(GeneratedArtworkClient.isPNG(image))
        XCTAssertTrue(GeneratedArtworkClient.isHeaderPNG(image))
        XCTAssertFalse(GeneratedArtworkClient.isHeaderPNG(original))
    }
}
