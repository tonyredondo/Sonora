import Foundation
import XCTest
@testable import SonoraCore

private actor ArtworkHTTP: MetadataLookupTransport {
    private(set) var calls: [URLRequest] = []
    var response: MetadataHTTPResponse
    init(_ response: MetadataHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) -> MetadataHTTPResponse { calls.append(request); return response }
}
final class GeneratedArtworkTests: XCTestCase {
    private var input: GeneratedArtworkInput { .init(title: "Quiet Horizon", artist: "Synthetic Artist", album: "First Light", albumDescription: "A record about beginnings.", genre: "Ambient", styles: ["Electronic"], moods: ["relaxed"]) }
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
