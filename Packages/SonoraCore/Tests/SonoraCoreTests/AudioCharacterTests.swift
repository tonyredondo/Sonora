import Foundation
import XCTest
@testable import SonoraCore

private actor CharacterTransport: MetadataLookupTransport {
    var responses: [MetadataHTTPResponse]
    private(set) var paths: [String] = []
    init(_ json: [String], statuses: [Int] = []) {
        responses = json.enumerated().map { MetadataHTTPResponse(data: Data($0.element.utf8), status: statuses.isEmpty ? 200 : statuses[$0.offset], contentType: "application/json") }
    }
    func send(_ request: URLRequest) throws -> MetadataHTTPResponse {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
        paths.append(request.url!.path)
        if request.httpMethod == "POST" {
            XCTAssertEqual(request.httpBody?.count, 32044)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            XCTAssertEqual(request.url?.query, "refresh=true")
        }
        return responses.removeFirst()
    }
}
final class AudioCharacterTests: XCTestCase {
    private let valid = #"{"version":"essentia-discogs-v1","silent":false,"styles":[{"label":"Rock---Indie Rock","score":0.3}],"moods":{"happy":0.2,"sad":0.8,"relaxed":0.9,"aggressive":0.1}}"#
    func testValidatesIdentityScoresAndKeepsMoodDisplayOrder() throws {
        let value = try JSONDecoder().decode(AudioCharacter.self, from: Data(valid.utf8))
        XCTAssertTrue(value.isValid); XCTAssertEqual(value.prominentMoods, ["sad", "relaxed"])
        for bad in [valid.replacingOccurrences(of: "essentia-discogs-v1", with: "other"), valid.replacingOccurrences(of: "0.3", with: "1.3"), valid.replacingOccurrences(of: "\"silent\":false", with: "\"silent\":true")] {
            XCTAssertFalse(try JSONDecoder().decode(AudioCharacter.self, from: Data(bad.utf8)).isValid)
        }
    }
    func testNegotiatesCapabilityAndSendsBoundedSampleToAuthenticatedEndpoint() async throws {
        let http = CharacterTransport([#"{"audio_character":{"enabled":true,"version":"essentia-discogs-v1"}}"#, valid])
        let client = AudioCharacterClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture-only"), transport: http)
        try await client.checkAvailability()
        let value = try await client.analyze(Data(repeating: 0, count: 32044), refresh: true)
        XCTAssertTrue(value.isValid)
        let paths = await http.paths
        XCTAssertEqual(paths, ["/v1/status", "/v1/audio/character"])
    }
    func testRejectsUnavailableAndUnauthorizedServersBeforeAudioUpload() async throws {
        for (body,code) in [("{}",200),("{}",401)] {
            let http = CharacterTransport([body], statuses: [code])
            let client = AudioCharacterClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture-only"), transport: http)
            do { try await client.checkAvailability(); XCTFail("Server must expose a compatible enabled capability") } catch { }
            let paths = await http.paths; XCTAssertEqual(paths, ["/v1/status"])
        }
    }
}
