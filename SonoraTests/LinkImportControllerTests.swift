import Foundation
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class LinkImportControllerTests: XCTestCase {
    func testCancellingLinkLookupClearsPendingStateWithoutAddingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SonoraTests.CancelLink.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("Artwork"))
        defer { library.cancelIndexing() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PendingLinkProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let requestStarted = expectation(description: "Lookup started")
        PendingLinkProtocol.started.set { requestStarted.fulfill() }
        defer { PendingLinkProtocol.started.set(nil) }
        let controller = LinkImportController(library: library, copies: LocalImportController(), client: WeTransferClient(session: session), directory: root)
        controller.start("https://wetransfer.com/downloads/synthetic/abc123", name: "")
        await fulfillment(of: [requestStarted], timeout: 5)
        XCTAssertTrue(controller.hasPendingImport)
        controller.cancel()
        let deadline = Date().addingTimeInterval(3)
        while controller.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.hasPendingImport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.json").path))
        XCTAssertTrue(library.state.sources.isEmpty)
    }

    func testRecoveredDownloadRegistersOnceAndReusesCopyWithoutNetwork() async throws {
        let files = FileManager.default, id = UUID()
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let download = root.appendingPathComponent("Downloads/\(id.uuidString)")
        try files.createDirectory(at: download, withIntermediateDirectories: true)
        defer {
            try? files.removeItem(at: root)
            if let record = try? LocalMusicImport.records().first(where: { $0.id == id.uuidString }) { try? LocalMusicImport.remove(record) }
        }
        let payload = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "transfer-import", withExtension: "zip"))
        try files.copyItem(at: payload, to: download.appendingPathComponent("payload.download"))
        let token = "recovered" + id.uuidString.replacingOccurrences(of: "-", with: "")
        let link = "https://wetransfer.com/downloads/\(token)/abc123"
        let pending: [String: Any] = ["id": id.uuidString, "input": link, "customName": "", "phase": "ready",
            "originID": "wetransfer:" + token, "name": "Recovered album", "filename": "album.zip", "bytes": 17813]
        try JSONSerialization.data(withJSONObject: pending).write(to: root.appendingPathComponent("pending.json"))
        let suite = "SonoraTests.RecoverLink.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("Artwork"))
        defer { library.cancelIndexing() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PendingLinkProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let controller = LinkImportController(library: library, copies: LocalImportController(), client: WeTransferClient(session: session), directory: root)
        XCTAssertTrue(controller.hasPendingImport)
        await controller.restore()
        try await waitForCompletion(controller)
        XCTAssertNil(controller.issue)
        XCTAssertEqual(controller.completedName, "Recovered album")
        XCTAssertEqual(library.state.sources.count, 1)
        XCTAssertEqual(library.state.songs.count, 1)
        XCTAssertFalse(files.fileExists(atPath: download.path))
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent("pending.json").path))
        controller.start(link, name: "Duplicate")
        try await waitForCompletion(controller)
        XCTAssertNil(controller.issue)
        XCTAssertEqual(controller.completedName, "Recovered album")
        XCTAssertEqual(library.state.sources.count, 1)
    }

    private func waitForCompletion(_ controller: LinkImportController) async throws {
        let deadline = Date().addingTimeInterval(10)
        while controller.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.hasPendingImport, controller.issue ?? controller.status)
    }

    func testProviderFailureSurvivesRelaunchAndCanBeRetriedAndDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SonoraTests.RetryLink.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(defaults: defaults, artworkDirectory: root.appendingPathComponent("Artwork"))
        defer { library.cancelIndexing() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FailedLinkProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let requests = expectation(description: "Initial request and retry"); requests.expectedFulfillmentCount = 2
        FailedLinkProtocol.started.set { requests.fulfill() }
        defer { FailedLinkProtocol.started.set(nil) }
        let controller = LinkImportController(library: library, copies: LocalImportController(), client: WeTransferClient(session: session), directory: root)
        controller.start("https://wetransfer.com/downloads/synthetic/abc123", name: "")
        try await waitForFailure(controller)
        XCTAssertTrue(controller.canRetry)
        XCTAssertTrue(controller.issue?.contains("503") == true)
        let restored = LinkImportController(library: library, copies: LocalImportController(), client: WeTransferClient(session: session), directory: root)
        await restored.restore()
        XCTAssertTrue(restored.canRetry)
        restored.retry()
        try await waitForFailure(restored)
        await fulfillment(of: [requests], timeout: 3)
        XCTAssertTrue(restored.canRetry)
        XCTAssertTrue(restored.issue?.contains("503") == true)
        restored.cancel()
        XCTAssertFalse(restored.hasPendingImport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.json").path))
        XCTAssertTrue(library.state.sources.isEmpty)
    }

    private func waitForFailure(_ controller: LinkImportController) async throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.hasPendingImport)
        XCTAssertFalse(controller.isImporting)
    }
}

private final class FailedLinkProtocol: URLProtocol {
    static let started = PendingLinkProtocol.Callback()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.started.fire()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class PendingLinkProtocol: URLProtocol {
    static let started = Callback()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.fire() }
    override func stopLoading() { }

    final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?
        func set(_ value: (() -> Void)?) { lock.withLock { action = value } }
        func fire() { let callback = lock.withLock { action }; callback?() }
    }
}
