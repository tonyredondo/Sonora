import Foundation
import XCTest
@testable import SonoraCore

private struct DiagnosticFailureFixture: MetadataLookupTransport {
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        let data = Data(#"{"error":"upstream_error","provider":"elevenlabs","upstream_status":429,"reason":"quota_exceeded","request_id":"b0b3276b-6850-49c2-858a-8f1ae4976b25","message":"private-lyrics secret-key https://private.example?token=secret"}"#.utf8)
        return MetadataHTTPResponse(data: data, status: 502, contentType: "application/json")
    }
}

private final class DiagnosticURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.hasSuffix("timeout") || request.url!.path.hasSuffix("cancel") {
            let code: URLError.Code = request.url!.path.hasSuffix("cancel") ? .cancelled : .timedOut
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSLocalizedDescriptionKey: "private-lyrics secret-key", NSURLErrorFailingURLErrorKey: request.url!]))
            return
        }
        let id = request.value(forHTTPHeaderField: "X-Sonora-Request-ID") ?? "missing"
        let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: ["Content-Type":"application/json", "X-Sonora-Request-ID":id])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"upstream_error","provider":"elevenlabs","upstream_status":429,"reason":"quota_exceeded","message":"private-lyrics secret-key"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class MetadataDiagnosticsTests: XCTestCase {
    private func transport(_ directory: URL, limit: Int = 1024) -> MetadataURLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiagnosticURLProtocol.self]
        return MetadataURLSessionTransport(session: URLSession(configuration: config), diagnostics: MetadataDiagnostics(directory: directory, maxBytes: limit))
    }
    private func records(_ directory: URL) throws -> [[String:String]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.flatMap { file in
            try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode([String:String].self, from: Data($0)) }
        }
    }

    func testTransportPersistsCorrelatedFailureWithoutBodyHeadersOrQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var request = URLRequest(url: URL(string:"http://127.0.0.1/v1/lyrics/transcribe?token=private-query")!)
        request.httpMethod = "POST"; request.httpBody = Data("private-lyrics".utf8)
        request.setValue("Bearer secret-key", forHTTPHeaderField:"Authorization")
        let result = try await transport(root).send(request)
        XCTAssertEqual(result.status, 502)
        let log = try records(root)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0]["request_id"], result.requestID)
        XCTAssertNotNil(result.requestID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(log[0]["operation"], "lyrics/transcribe")
        XCTAssertEqual(log[0]["upstream_status"], "429")
        XCTAssertEqual(log[0]["reason"], "quota_exceeded")
        XCTAssertNotNil(log[0]["elapsed_ms"])
        for value in ["private-query", "private-lyrics", "secret-key", "Authorization"] { XCTAssertFalse(String(describing:log).contains(value)) }
    }

    func testTimeoutRetainsDomainCodeAndReferenceWhileCancellationIsNotAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let http = transport(root)
        do {
            _ = try await http.send(URLRequest(url: URL(string:"http://127.0.0.1/timeout?token=secret-key")!)); XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-1001") && error.localizedDescription.contains("Referencia:"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
        let log = try records(root)
        XCTAssertEqual(log.first?["error_domain"], "NSURLErrorDomain")
        XCTAssertEqual(log.first?["error_code"], "-1001")
        do { _ = try await http.send(URLRequest(url: URL(string:"http://127.0.0.1/cancel")!)); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        XCTAssertEqual(try records(root).count, 1)
    }

    func testConcurrentFailuresRotatePrivateFilesAndSurviveLoggerRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = MetadataDiagnostics(directory: root, maxBytes: 1024)
        await withTaskGroup(of:Void.self) { group in
            for _ in 0..<60 {
                group.addTask { await diagnostics.recordFailure(NSError(domain:NSCocoaErrorDomain, code:4, userInfo:[NSLocalizedDescriptionKey:"private-lyrics secret-key"]), stage:.lyricsLoad) }
            }
        }
        await MetadataDiagnostics(directory:root, maxBytes:1024).recordFailure(MetadataLookupError.cacheUnavailable, stage:.lyricsSave)
        let files = try FileManager.default.contentsOfDirectory(at:root, includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
            XCTAssertLessThanOrEqual((attributes[.size] as! NSNumber).intValue, 1024)
            XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue & 0o777, 0o600)
        }
        let log = try records(root)
        XCTAssertTrue(log.contains { $0["stage"] == "lyricsSave" })
        XCTAssertFalse(String(describing:log).contains("private-lyrics"))
        XCTAssertFalse(String(describing:log).contains("secret-key"))
    }

    func testLoggingFailureCannotReplaceTheOriginalHTTPResponse() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:path) }
        try Data().write(to:path)
        let result = try await transport(path).send(URLRequest(url:URL(string:"http://127.0.0.1/v1/lyrics/transcribe")!))
        XCTAssertEqual(result.status, 502)
    }
    func testAudioErrorRetainsDomainAndUnderlyingCodesWithoutUserInfo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let privateCause = NSError(domain:"private-lyrics secret-key",code:99)
        let underlying = NSError(domain:NSOSStatusErrorDomain,code:-54,userInfo:[NSUnderlyingErrorKey:privateCause,NSFilePathErrorKey:"/private/song.flac",NSLocalizedDescriptionKey:"private-lyrics secret-key"])
        let error = NSError(domain:"org.sbooth.AudioEngine.AudioDecoder",code:1,userInfo:[NSUnderlyingErrorKey:underlying,NSLocalizedDescriptionKey:"private-lyrics secret-key"])
        await MetadataDiagnostics(directory:root).recordFailure(error,stage:.lyricsLoad)
        let log = try XCTUnwrap(records(root).first)
        XCTAssertEqual(log["error_domain"],"org.sbooth.AudioEngine.AudioDecoder")
        XCTAssertEqual(log["underlying_1_domain"],NSOSStatusErrorDomain)
        XCTAssertEqual(log["underlying_1_code"],"-54")
        XCTAssertNil(log["underlying_2_domain"])
        for privateValue in ["/private/song.flac","private-lyrics","secret-key"] { XCTAssertFalse(String(describing:log).contains(privateValue)) }
    }

    func testAnalysisFailureShowsServerCauseAndReferenceWithoutRawProviderText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LyricsSynchronizationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "secret-key"), cache: MetadataLookupCache(directory: root), transport: DiagnosticFailureFixture(), diagnostics: MetadataDiagnostics(directory:root.appendingPathComponent("Diagnostics")))
        do {
            _ = try await client.transcription(duration: 2, offline: false) { pcmFixture() }
            XCTFail("The provider failure must remain an error")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("ElevenLabs"), description)
            XCTAssertTrue(description.contains("429") && description.contains("502"), description)
            XCTAssertTrue(description.contains("quota_exceeded"), description)
            XCTAssertTrue(description.contains("b0b3276b-6850-49c2-858a-8f1ae4976b25"), description)
            for value in ["private-lyrics", "secret-key", "private.example"] { XCTAssertFalse(description.contains(value), description) }
        }
    }
}
