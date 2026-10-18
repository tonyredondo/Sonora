import Foundation
import SonoraCore
import XCTest
@testable import Sonora

private actor ArchiveAcknowledgements: MetadataLookupTransport {
    private(set) var requests: [URLRequest] = []
    var status = 201
    func reject(_ rejected: Bool) { status = rejected ? 401 : 201 }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        requests.append(request)
        let copy = try JSONDecoder().decode(ConfirmedMetadataRecord.self,from:request.httpBody ?? Data())
        return MetadataHTTPResponse(data:try JSONSerialization.data(withJSONObject:["id":copy.id.uuidString]),status:status,contentType:"application/json")
    }
}

final class MetadataArchiveIntegrationTests: XCTestCase {
    private func waitForPending(_ count: Int, store: MetadataArchiveStore, server: URL) async throws {
        for _ in 0..<200 {
            if try await store.pendingCount(server:server) == count { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Pending copies did not reach the expected state")
    }
    @MainActor func testSingleAndBatchFileSavesCreateDurableCopiesWhileConflictsDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("music"), archiveDirectory = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at:music,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"flac"))
        for name in ["a.flac","b.flac"] { try FileManager.default.copyItem(at:fixture,to:music.appendingPathComponent(name)) }
        let suite = "SonoraTests.MetadataArchive.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18443",token:"unused-test-token"); settings.offline = true
        let store = MetadataArchiveStore(directory:archiveDirectory)
        let transport = ArchiveAcknowledgements()
        let backup = MetadataArchiveController(settings:settings,store:store,transport:transport)
        let player = PlaybackController(defaults:defaults,metadataArchive:backup); defer { player.stop(); backup.pause() }
        await player.loadFolder(music,autoPlay:false)
        let a = try XCTUnwrap(AudioTrack(relativePath:"a.flac")), b = try XCTUnwrap(AudioTrack(relativePath:"b.flac"))
        let initial = try await player.readMetadata(for:a)
        try await player.saveMetadata(for:a,expected:initial.fingerprint,patch:MetadataPatch(values:[.artist:"Confirmed artist",.album:"Confirmed edition",.lyrics:LyricsDocument.aiTranscriptionMarker + "\n[00:00.10]A line"]))
        let saved = try await player.readMetadata(for:a), second = try await player.readMetadata(for:b)
        let audioID = try await AudioContentIdentity.read(track:a,folder:player.folderAccess(for:a),expected:saved.fingerprint)
        let batch = await player.saveMetadataBatch([a,b],expected:[a.id:saved.fingerprint,b.id:second.fingerprint],patch:MetadataPatch(values:[.genre:"Rock"])) { _ in }
        XCTAssertEqual(batch.written,2); XCTAssertTrue(batch.failures.isEmpty)
        do { try await player.saveMetadata(for:a,expected:initial.fingerprint,patch:MetadataPatch(values:[.artist:"Stale edit"])); XCTFail("A conflict must not create a confirmed copy") }
        catch { XCTAssertEqual(error.localizedDescription,MetadataIOError.changed.localizedDescription) }
        let reopened = MetadataArchiveStore(directory:archiveDirectory)
        let copies = try await reopened.summaries(audioID:audioID,server:URL(string:settings.endpoint))
        XCTAssertEqual(copies.count,3)
        var containsConfirmed = false
        for copy in copies {
            if let record = try await reopened.record(copy.id,audioID:audioID,server:URL(string:settings.endpoint)), record.values["album"] == "Confirmed edition" && record.values["artist"] == "Confirmed artist" && record.values["genre"] == "Rock" { containsConfirmed = true }
        }
        XCTAssertTrue(containsConfirmed)
        let pending = try await reopened.pendingCount(server:XCTUnwrap(URL(string:settings.endpoint)))
        XCTAssertEqual(pending,3)
        XCTAssertNil(backup.issue)
        backup.start()
        settings.offline = false
        try await waitForPending(0,store:store,server:XCTUnwrap(URL(string:settings.endpoint)))
        let uploaded = try await store.pendingCount(server:URL(string:settings.endpoint)!)
        let requests = await transport.requests
        XCTAssertEqual(uploaded,0); XCTAssertEqual(requests.count,3)
        for _ in 0..<200 where backup.synchronizing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(backup.pending,0)

        settings.offline = true
        let before = try await player.readMetadata(for:a)
        try await player.saveMetadata(for:a,expected:before.fingerprint,patch:MetadataPatch(values:[.genre:"Jazz"]))
        await transport.reject(true); settings.offline = false
        for _ in 0..<200 where backup.issue == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(backup.issue)
        let rejected = try await store.pendingCount(server:URL(string:settings.endpoint)!)
        XCTAssertEqual(rejected,1)
        await transport.reject(false); backup.retry()
        try await waitForPending(0,store:store,server:XCTUnwrap(URL(string:settings.endpoint)))
        let retried = try await store.pendingCount(server:URL(string:settings.endpoint)!)
        XCTAssertEqual(retried,0)
        for _ in 0..<200 where backup.synchronizing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(backup.pending,0)
        try await settings.cache.clear()
        let retained = try await reopened.summaries(audioID:audioID,server:URL(string:settings.endpoint))
        XCTAssertEqual(retained.count,4)
    }
}
