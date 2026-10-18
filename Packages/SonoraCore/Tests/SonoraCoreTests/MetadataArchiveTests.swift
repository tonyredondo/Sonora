import Foundation
import XCTest
@testable import SonoraCore

private actor ArchiveHTTPFixture: MetadataLookupTransport {
    var requests: [URLRequest] = []
    var response: MetadataHTTPResponse
    var acknowledgeUploads = false
    func enableDelayedAcknowledgements() { acknowledgeUploads = true }
    init(status: Int = 201, data: Data = Data()) {
        response = MetadataHTTPResponse(data: data, status: status, contentType: "application/json")
    }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        requests.append(request)
        if acknowledgeUploads {
            try await Task.sleep(nanoseconds:100_000_000)
            let record = try JSONDecoder().decode(ConfirmedMetadataRecord.self,from:request.httpBody ?? Data())
            return MetadataHTTPResponse(data:try JSONSerialization.data(withJSONObject:["id":record.id.uuidString]),status:201,contentType:"application/json")
        }
        return response
    }
}

final class MetadataArchiveTests: XCTestCase {
    private let audioID = "pcm64-v1:" + String(repeating: "a", count: 64)
    private let otherAudio = "pcm64-v1:" + String(repeating: "b", count: 64)
    private func record(album: String = "Original", audioID: String? = nil) throws -> ConfirmedMetadataRecord {
        try ConfirmedMetadataRecord(audioID: audioID ?? self.audioID,
            values: [.title:"Song", .artist:"Artist", .album:album,
                     .lyrics:LyricsDocument.aiTranscriptionMarker + "\n[00:01.25]A line"],
            artwork: Data([0xff,0xd8,0xff,0xd9]))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func allCopies(_ store: MetadataArchiveStore, server: URL) async throws -> [ConfirmedMetadataRecord] {
        var result: [ConfirmedMetadataRecord] = []
        for summary in try await store.summaries(audioID:audioID,server:server) {
            if let record = try await store.record(summary.id,audioID:audioID,server:server) { result.append(record) }
        }
        return result
    }

    func testOfflineConfirmedCopiesSurviveRecreationAndKeepEditionsAndAudioSeparate() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string:"http://127.0.0.1:8089")!
        let first = try record(), second = try record(album:"Reissue"), unrelated = try record(audioID:otherAudio)
        let store = MetadataArchiveStore(directory:directory)
        try await store.confirm(first, server:endpoint)
        try await store.confirm(second, server:endpoint)
        try await store.confirm(unrelated, server:endpoint)
        let reopened = MetadataArchiveStore(directory:directory)
        let copies = try await allCopies(reopened,server:endpoint)
        XCTAssertEqual(Set(copies.map { $0.values["album"] ?? "" }), ["Original","Reissue"])
        XCTAssertEqual(copies.first?.artwork, Data([0xff,0xd8,0xff,0xd9]))
        XCTAssertTrue(copies.allSatisfy { LyricsDocument(text:$0.values["lyrics"] ?? "").attribution == "Transcrita por IA · ElevenLabs" })
        let pending = try await reopened.pendingCount(server:endpoint)
        XCTAssertEqual(pending,3)
        let otherServer = try await allCopies(reopened,server:URL(string:"http://127.0.0.1:8090")!)
        XCTAssertTrue(otherServer.isEmpty)
    }

    func testSuccessfulRetryUploadsOnlyConfirmedMetadataAndDoesNotLoseOfflineCopy() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let record = try record(), endpoint = URL(string:"http://127.0.0.1:8089")!
        let ack = try JSONSerialization.data(withJSONObject:["id":record.id.uuidString])
        let transport = ArchiveHTTPFixture(data:ack)
        let client = MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:endpoint.absoluteString,token:"test-only-token"),transport:transport)
        let store = MetadataArchiveStore(directory:directory)
        try await store.confirm(record,server:endpoint)
        _ = try await store.synchronize(client:client)
        let pending = try await store.pendingCount(server:endpoint)
        XCTAssertEqual(pending,0)
        let requests = await transport.requests
        XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests[0].httpMethod,"PUT")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField:"Authorization"),"Bearer test-only-token")
        let payload = try JSONDecoder().decode(ConfirmedMetadataRecord.self,from:XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(payload,record)
        let reopened = MetadataArchiveStore(directory:directory)
        let recovered = try await allCopies(reopened,server:endpoint)
        XCTAssertEqual(recovered,[record])
        let files = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "plist" }
        for file in files { XCTAssertFalse(try Data(contentsOf:file).contains(Data("test-only-token".utf8))) }
    }

    func testRejectedUploadRemainsPendingAndChangingServerDoesNotForwardIt() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let endpoint = URL(string:"http://127.0.0.1:8089")!, alternate = URL(string:"http://127.0.0.1:8090")!
        let store = MetadataArchiveStore(directory:directory)
        try await store.confirm(record(),server:endpoint)
        let rejected = ArchiveHTTPFixture(status:401)
        let client = MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:endpoint.absoluteString,token:"test"),transport:rejected)
        do { _ = try await store.synchronize(client:client); XCTFail("Authorization failure must remain visible") }
        catch { XCTAssertEqual(error as? MetadataLookupError,.unauthorized) }
        let different = ArchiveHTTPFixture()
        _ = try await store.synchronize(client:MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:alternate.absoluteString,token:"test"),transport:different))
        let requests = await different.requests, pending = try await store.pendingCount(server:endpoint)
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(pending,1)
    }

    func testDownloadedRecordCannotBeAppliedToDifferentAudioAndInvalidTagsStayOutOfArchive() async throws {
        let record = try record(audioID:otherAudio)
        let transport = ArchiveHTTPFixture(status:200,data:try JSONEncoder().encode(record))
        let client = MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:"http://127.0.0.1:8089",token:"test"),transport:transport)
        do { _ = try await client.record(record.id,audioID:audioID); XCTFail("A server ID must not bypass the audio match") }
        catch { XCTAssertEqual(error as? MetadataArchiveError,.invalidRecord) }
        XCTAssertThrowsError(try ConfirmedMetadataRecord(audioID:audioID,values:[.trackNumber:"-1"],artwork:nil))
    }

    func testLargestAllowedArtworkAndEscapedLyricsFitTheUploadContract() async throws {
        let record = try ConfirmedMetadataRecord(audioID:audioID,values:[.lyrics:String(repeating:"\"",count:1_000_000)],artwork:Data(repeating:255,count:10_000_000))
        let transport = ArchiveHTTPFixture(data:try JSONSerialization.data(withJSONObject:["id":record.id.uuidString]))
        let client = MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:"http://127.0.0.1:8089",token:"test"),transport:transport)
        try await client.save(record)
        let requests = await transport.requests
        let body = try XCTUnwrap(requests.first?.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(ConfirmedMetadataRecord.self,from:body),record)
    }

    func testLoopbackProxyInteroperability() async throws {
        guard let address = ProcessInfo.processInfo.environment["SONORA_ARCHIVE_TEST_ENDPOINT"] else { throw XCTSkip("Requires the isolated local Rust proxy fixture") }
        let url = try XCTUnwrap(URL(string:address))
        XCTAssertEqual(url.host,"127.0.0.1")
        guard url.host == "127.0.0.1", url.port != 8089 else { throw MetadataArchiveError.invalidRecord }
        let connection = try MetadataProxyConnection(endpoint:address,token:"archive-integration-fixture-token")
        let client = MetadataArchiveClient(connection:connection)
        let copy = try record(album:"Interop " + UUID().uuidString)
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let store = MetadataArchiveStore(directory:directory)
        try await store.confirm(copy,server:url)
        _ = try await store.synchronize(client:client)
        let restored = try await client.record(copy.id,audioID:audioID)
        XCTAssertEqual(restored,copy)
        let page = try await client.list(audioID:audioID)
        XCTAssertTrue(page.records.contains { $0.id == copy.id && $0.album == copy.values["album"] })
        // Retry the exact same body through the real Rust endpoint, then retain an offline copy.
        try await client.save(copy)
        let reopened = MetadataArchiveStore(directory:directory)
        let copies = try await allCopies(reopened,server:url)
        XCTAssertEqual(copies,[copy])
    }

    func testOverlappingSynchronizationDoesNotLeaveANewConfirmationStranded() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at:directory) }
        let endpoint = URL(string:"http://127.0.0.1:8089")!, transport = ArchiveHTTPFixture()
        await transport.enableDelayedAcknowledgements()
        let client = MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:endpoint.absoluteString,token:"test"),transport:transport)
        let store = MetadataArchiveStore(directory:directory)
        try await store.confirm(record(album:"First"),server:endpoint)
        let first = Task { try await store.synchronize(client:client,limit:1) }
        for _ in 0..<1000 {
            if !(await transport.requests).isEmpty { break }
            try await Task.sleep(nanoseconds:2_000_000)
        }
        let started = await transport.requests
        XCTAssertEqual(started.count,1)
        try await store.confirm(record(album:"Second"),server:endpoint)
        let second = Task { try await store.synchronize(client:client) }
        _ = try await first.value; _ = try await second.value
        let pending = try await store.pendingCount(server:endpoint)
        XCTAssertEqual(pending,0,"A foreground/reconnection attempt must wait for the previous request rather than dropping the new work")
    }
}
