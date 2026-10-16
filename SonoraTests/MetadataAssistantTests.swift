import Foundation
import SonoraCore
import XCTest
@testable import Sonora

final class MetadataAssistantTests: XCTestCase {
    @MainActor
    func testConnectionStoresTokenInKeychainAndEndpointSeparately() async throws {
        let suite = "SonoraTests.Assistant.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataTokenStore(service: suite)
        defer { try? store.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: store, cache: MetadataLookupCache(directory: root))
        try settings.save(endpoint: "http://127.0.0.1:8089", token: "test-only-proxy-token")
        XCTAssertEqual(try store.read(), "test-only-proxy-token")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("test-only-proxy-token") == true })
        settings.offline = true
        let reopened = MetadataAssistantSettings(defaults: defaults, tokens: store, cache: MetadataLookupCache(directory: root))
        XCTAssertEqual(reopened.endpoint, "http://127.0.0.1:8089")
        XCTAssertTrue(reopened.offline)
        XCTAssertTrue(reopened.hasToken)
    }

    @MainActor
    func testOneTimeBootstrapIsConsumedAndInvalidInputDoesNotOverwriteConnection() throws {
        let suite = "SonoraTests.Assistant.Bootstrap.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataTokenStore(service: suite); defer { try? store.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ProxyConnection.json")
        try JSONSerialization.data(withJSONObject: ["endpoint": "http://127.0.0.1:8089", "token": "test-only-bootstrap-token"]).write(to: file)
        let settings = MetadataAssistantSettings(defaults: defaults, tokens: store, cache: MetadataLookupCache(directory: root.appendingPathComponent("cache")))
        try settings.importConnection(from: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try store.read(), "test-only-bootstrap-token")
        XCTAssertThrowsError(try settings.save(endpoint: "http://example.com", token: "other-token"))
        XCTAssertEqual(try store.read(), "test-only-bootstrap-token")
        XCTAssertEqual(settings.endpoint, "http://127.0.0.1:8089")
    }
}
