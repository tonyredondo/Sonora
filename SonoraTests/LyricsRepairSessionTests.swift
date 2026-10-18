import AVFAudio
import CryptoKit
import Foundation
import SonoraCore
import XCTest
@testable import Sonora

private actor RepairAudioFixture: MetadataLookupTransport {
    private(set) var calls = 0
    let synced: String
    init(missingVerse: Bool = true, boundaryAddition: Bool = false) {
        let first = boundaryAddition ? "Bright road again" : "Bright road", last = boundaryAddition ? "Now return" : "We return"
        synced = "[00:00.10]" + first + (missingVerse ? "\n[00:01.40]Walk beside me" : "") + "\n[00:03.10]" + last
    }
    init(synced: String) { self.synced = synced }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        calls += 1
        XCTAssertEqual(request.url?.path,"/v1/lyrics/transcribe")
        let body = try XCTUnwrap(request.httpBody), start = try XCTUnwrap(body.range(of:Data("RIFF".utf8))).lowerBound
        let count = body[(start + 40)..<(start + 44)].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        let audio = Data(body[start..<(start + 44 + count)])
        let hash = SHA256.hash(data:audio).map { String(format:"%02x",$0) }.joined()
        let plain = LyricsDocument(text:synced).lines.map(\.text).joined(separator:"\n")
        let value: [String:Any] = ["plain_lyrics":plain,"synced_lyrics":synced,"audio_sha256":hash,"duration":Double(count) / 32000,"model_id":"scribe_v2"]
        return MetadataHTTPResponse(data:try JSONSerialization.data(withJSONObject:["sources":[],"data":value]),status:200,contentType:"application/json")
    }
}
private actor CancelledRepairFixture: MetadataLookupTransport {
    private(set) var started = false
    private(set) var cancelled = false
    func send(_ request:URLRequest) async throws -> MetadataHTTPResponse {
        started = true
        do { try await Task.sleep(for:.milliseconds(400)) }
        catch { cancelled = true; throw error }
        throw MetadataLookupError.unavailable
    }
}

final class LyricsRepairSessionTests: XCTestCase {
    @MainActor func testLegacyCachedChorusesAndOffsetsSurviveOfflineRepairAndSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("repair.mp3")
        try FileManager.default.copyItem(at:XCTUnwrap(Bundle(for:Self.self).url(forResource:"lyrics-repair-vbr",withExtension:"mp3")),to:url)
        let suite = "SonoraTests.RepairLegacy.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18444",token:"synthetic-repair-token")
        let source = "[00:00.10]We sing brightly\n[00:01.40]home come home\n[00:02.00]Come back\n[00:03.10]Come back"
        let player = PlaybackController(defaults:defaults), transport = RepairAudioFixture(synced:source)
        defer { player.stop() }
        await player.loadFolder(root,autoPlay:false)
        let track = try XCTUnwrap(AudioTrack(relativePath:"repair.mp3"))
        let initial = try await player.readMetadata(for:track)
        let original = "[offset:invalid]\n[offſet:500]\n[00:00.60]We sing softly\n[00:02.50]Come home\n[00:03.60]Come home"
        try await player.saveMetadata(for:track,expected:initial.fingerprint,patch:MetadataPatch(values:[.lyrics:original]))
        let before = try await player.readMetadata(for:track), folder = try player.folderAccess(for:track)
        let identity = try await AudioContentIdentity.read(track:track,folder:folder,expected:before.fingerprint)
        let duration = try await LyricsAudioPreparation.duration(track:track,folder:folder,expected:before.fingerprint)
        let pcm = try await LyricsAudioPreparation.prepare(track:track,folder:folder,expected:before.fingerprint)
        let connection = try MetadataProxyConnection(endpoint:settings.endpoint,token:settings.savedToken())
        let client = LyricsSynchronizationClient(connection:connection,cache:settings.cache,transport:transport)
        _ = try await client.synchronize(query:MetadataSearch(title:""),duration:duration,lyrics:"",offline:false) { pcm }
        settings.offline = true
        let session = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await session.load(); await session.analyze()
        XCTAssertNil(session.issue); XCTAssertTrue(session.isCached); XCTAssertTrue(session.review?.usesPhraseTiming == true)
        for change in try XCTUnwrap(session.review).proposals { session.accept(change) }
        session.onlyCompletions = true
        XCTAssertEqual(LyricsDocument(text:try session.draft()).lines.map(\.text),["We sing softly","home come home","Come home","Come home"])
        session.onlyCompletions = false
        let draft = try session.draft()
        XCTAssertEqual(LyricsDocument(text:draft).lines.map(\.time),[0.1,1.4,2,3.1])
        await session.save(draft)
        XCTAssertTrue(session.saved); XCTAssertNil(session.issue)
        let written = try await player.readMetadata(for:track)
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.text),["We sing brightly","home come home","Come back","Come back"])
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.time),[0.1,1.4,2,3.1])
        let after = try await AudioContentIdentity.read(track:track,folder:folder,expected:written.fingerprint)
        XCTAssertEqual(identity,after)
        let reopened = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await reopened.load(); await reopened.analyze()
        XCTAssertNil(reopened.issue); XCTAssertTrue(reopened.isCached); XCTAssertTrue(reopened.review?.proposals.isEmpty == true)
        let calls = await transport.calls; XCTAssertEqual(calls,1,"The old no-word-details cache is shared by transcription and repair, including after tag writes")
    }
    @MainActor func testBoundaryCompletionAndCorrectionKeepTheirTimesThroughSaveAndOfflineReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("repair.mp3")
        try FileManager.default.copyItem(at:XCTUnwrap(Bundle(for:Self.self).url(forResource:"lyrics-repair-vbr",withExtension:"mp3")),to:url)
        let suite = "SonoraTests.RepairBoundary.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18444",token:"synthetic-repair-token")
        let player = PlaybackController(defaults:defaults), transport = RepairAudioFixture(boundaryAddition:true)
        defer { player.stop() }
        await player.loadFolder(root,autoPlay:false)
        let track = try XCTUnwrap(AudioTrack(relativePath:"repair.mp3"))
        let initial = try await player.readMetadata(for:track)
        try await player.saveMetadata(for:track,expected:initial.fingerprint,patch:MetadataPatch(values:[.lyrics:"[00:00.10]Bright road\n[00:03.10]We return"]))
        let before = try await player.readMetadata(for:track)
        let identity = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:before.fingerprint)
        let session = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await session.load(); await session.analyze()
        XCTAssertNil(session.issue)
        for change in try XCTUnwrap(session.review).proposals { session.accept(change) }
        session.onlyCompletions = true
        XCTAssertEqual(LyricsDocument(text:try session.draft()).lines.map(\.text),["Bright road again","Walk beside me","We return"])
        session.onlyCompletions = false
        let draft = try session.draft()
        XCTAssertEqual(LyricsDocument(text:draft).lines.map(\.time),[0.1,1.4,3.1])
        await session.save(draft)
        XCTAssertTrue(session.saved); XCTAssertNil(session.issue)
        let written = try await player.readMetadata(for:track)
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.text),["Bright road again","Walk beside me","Now return"])
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.time),[0.1,1.4,3.1])
        let after = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:written.fingerprint)
        XCTAssertEqual(identity,after)
        settings.offline = true
        let reopened = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await reopened.load(); await reopened.analyze()
        XCTAssertNil(reopened.issue); XCTAssertTrue(reopened.isCached); XCTAssertTrue(reopened.review?.proposals.isEmpty == true)
        let calls = await transport.calls; XCTAssertEqual(calls,1)
    }
    @MainActor func testVariableBitrateMP3UsesDecodedDurationForRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let mp3 = root.appendingPathComponent("repair.mp3")
        // Four-second synthetic sine, VBR without Xing: ffmpeg -f lavfi
        // -i sine=frequency=440:sample_rate=44100:duration=4 -c:a libmp3lame -q:a 2 -write_xing 0 lyrics-repair-vbr.mp3
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"lyrics-repair-vbr",withExtension:"mp3"))
        try FileManager.default.copyItem(at:fixture,to:mp3)
        let suite = "SonoraTests.RepairMP3.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18444",token:"synthetic-repair-token")
        let player = PlaybackController(defaults:defaults), transport = RepairAudioFixture(missingVerse:false)
        defer { player.stop() }
        await player.loadFolder(root,autoPlay:false)
        let track = try XCTUnwrap(AudioTrack(relativePath:"repair.mp3"))
        let initial = try await player.readMetadata(for:track)
        try await player.saveMetadata(for:track,expected:initial.fingerprint,patch:MetadataPatch(values:[.lyrics:"[00:00.10]Bright roan\n[00:01.40]Keep this verse\n[00:02.20]And this line\n[00:03.10]We return"]))
        let before = try await player.readMetadata(for:track)
        let pcm = try await LyricsAudioPreparation.prepare(track:track,folder:player.folderAccess(for:track),expected:before.fingerprint)
        let decodedDuration = Double(pcm.count - 44) / 32000
        XCTAssertGreaterThan(abs(decodedDuration - before.duration),0.1,"Fixture must exercise an inaccurate metadata duration")
        let identity = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:before.fingerprint)
        let session = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await session.load(); await session.analyze()
        XCTAssertNil(session.issue,"Decoded duration \(decodedDuration), metadata duration \(before.duration)")
        XCTAssertNotNil(session.review)
        let calls = await transport.calls; XCTAssertEqual(calls,1)
        let omitted = try XCTUnwrap(session.review?.proposals.first { $0.kind == .unrecognized })
        XCTAssertTrue(session.canListen)
        session.listen(omitted)
        XCTAssertEqual(try XCTUnwrap(session.previewEnd),3.4,accuracy:0.001,"Snippet must use the full original block and decoded song duration")
        player.seek(to:2.8); session.checkPreview(); XCTAssertNotNil(session.previewEnd)
        player.seek(to:3.5); session.checkPreview(); XCTAssertNil(session.previewEnd)
        for change in try XCTUnwrap(session.review).proposals where change.kind != .unrecognized { session.accept(change) }
        await session.save(try session.draft())
        XCTAssertTrue(session.saved); XCTAssertNil(session.issue)
        let written = try await player.readMetadata(for:track)
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.text),["Bright road","Keep this verse","And this line","We return"])
        let after = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:written.fingerprint)
        XCTAssertEqual(identity,after)
        settings.offline = true
        let reopened = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await reopened.load(); await reopened.analyze()
        XCTAssertNil(reopened.issue); XCTAssertTrue(reopened.isCached)
        let finalCalls = await transport.calls; XCTAssertEqual(finalCalls,1)
    }
    @MainActor func testReviewCancelOfflineReuseSaveAndConflictUseTheRealFilePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("repair.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:64000)); buffer.frameLength = 64000
        buffer.int16ChannelData![0].initialize(repeating:0,count:64000)
        try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:false).write(from:buffer)
        let suite = "SonoraTests.Repair.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18444",token:"synthetic-repair-token")
        let transport = RepairAudioFixture(), player = PlaybackController(defaults:defaults)
        defer { player.stop() }
        await player.loadFolder(root,autoPlay:false)
        let track = try XCTUnwrap(AudioTrack(relativePath:"repair.wav"))
        let before = try await player.readMetadata(for:track)
        try await player.saveMetadata(for:track,expected:before.fingerprint,patch:MetadataPatch(values:[.lyrics:"[00:00.10]Bright road\nUntimed words"]))
        let invalid = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await invalid.load(); await invalid.analyze()
        let invalidCalls = await transport.calls
        XCTAssertEqual(invalidCalls,0,"Invalid original lyrics must be rejected before an audio upload can consume credits")
        XCTAssertTrue(invalid.issue?.contains("mezcla líneas") == true)
        let validBefore = try await player.readMetadata(for:track)
        let original = "[00:00.10]Bright roan\n[00:02.00]\n[00:03.10]We return"
        try await player.saveMetadata(for:track,expected:validBefore.fingerprint,patch:MetadataPatch(values:[.lyrics:original]))
        let cancelledTransport = CancelledRepairFixture()
        let cancelledSession = LyricsRepairSession(player:player,track:track,settings:settings,transport:cancelledTransport)
        await cancelledSession.load()
        let pending = Task { await cancelledSession.analyze() }
        for _ in 0..<200 {
            if await cancelledTransport.started { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        let started = await cancelledTransport.started; XCTAssertTrue(started)
        cancelledSession.cancel(); await pending.value
        let cancelled = await cancelledTransport.cancelled; XCTAssertTrue(cancelled,"Closing the review must cancel its actual transport task")
        let originalID = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:try await player.readMetadata(for:track).fingerprint)
        let session = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await session.load(); await session.analyze()
        XCTAssertNil(session.issue); XCTAssertEqual(session.review?.proposals.count,2)
        await session.analyze()
        let calls = await transport.calls; XCTAssertEqual(calls,1)
        for change in try XCTUnwrap(session.review).proposals { session.accept(change) }
        let draft = try session.draft()
        let unchanged = try await player.readMetadata(for:track); XCTAssertEqual(unchanged.values[.lyrics],original)
        session.cancel()
        settings.offline = true
        let reopened = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await reopened.load(); await reopened.analyze()
        XCTAssertNil(reopened.issue); XCTAssertTrue(reopened.isCached)
        for change in try XCTUnwrap(reopened.review).proposals { reopened.accept(change) }
        let offlineDraft = try reopened.draft(); XCTAssertEqual(offlineDraft,draft)
        await reopened.save(offlineDraft)
        XCTAssertTrue(reopened.saved); XCTAssertNil(reopened.issue)
        let written = try await player.readMetadata(for:track)
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.text),["Bright road","Walk beside me","","We return"])
        XCTAssertEqual(LyricsDocument(text:written.values[.lyrics] ?? "").lines.map(\.time),[0.1,1.4,2,3.1])
        XCTAssertTrue(LyricsDocument(text:written.values[.lyrics] ?? "").isAIRepaired)
        let finalID = try await AudioContentIdentity.read(track:track,folder:player.folderAccess(for:track),expected:written.fingerprint)
        XCTAssertEqual(originalID,finalID)
        // The older review cannot overwrite the newer file, even with valid cached audio.
        await session.save(draft)
        XCTAssertFalse(session.saved); XCTAssertNotNil(session.issue)
        let afterConflict = try await player.readMetadata(for:track); XCTAssertEqual(afterConflict.values[.lyrics],written.values[.lyrics])

        // A valid edit word can form a metadata tag with the original brackets.
        // Reject the draft before it becomes an approved save, using cached audio.
        try await player.saveMetadata(for:track,expected:afterConflict.fingerprint,patch:MetadataPatch(values:[.lyrics:"[Singer:Guest]\nWe return"]))
        let beforeUnsafeDraft = try Data(contentsOf:url)
        let unsafe = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
        await unsafe.load(); await unsafe.analyze()
        XCTAssertNil(unsafe.issue); XCTAssertTrue(unsafe.isCached)
        let change = try XCTUnwrap(unsafe.review?.proposals.first { $0.original == "Singer:Guest" })
        unsafe.setEdit(change,text:"ar:Guest",startTime:nil)
        XCTAssertThrowsError(try unsafe.draft())
        await unsafe.save(LyricsDocument.aiRepairMarker + "\n[ar:Guest]\nWe return")
        XCTAssertFalse(unsafe.saved); XCTAssertEqual(unsafe.issue,LyricsRepairError.invalidSelection.localizedDescription)
        XCTAssertEqual(try Data(contentsOf:url),beforeUnsafeDraft)
        let finalCalls = await transport.calls; XCTAssertEqual(finalCalls,1)
    }
    @MainActor func testChangedOrRemovedSidecarRejectsSaveWithoutChangingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("repair.mp3"), sidecar = root.appendingPathComponent("repair.lrc")
        try FileManager.default.copyItem(at:XCTUnwrap(Bundle(for:Self.self).url(forResource:"lyrics-repair-vbr",withExtension:"mp3")),to:url)
        let suite = "SonoraTests.RepairSidecar.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let tokens = MetadataTokenStore(service:suite); defer { try? tokens.remove() }
        let settings = MetadataAssistantSettings(defaults:defaults,tokens:tokens,cache:MetadataLookupCache(directory:root.appendingPathComponent("cache")))
        try settings.save(endpoint:"http://127.0.0.1:18444",token:"synthetic-repair-token")
        let player = PlaybackController(defaults:defaults), transport = RepairAudioFixture()
        defer { player.stop() }
        let track = try XCTUnwrap(AudioTrack(relativePath:"repair.mp3")), original = try Data(contentsOf:url)
        for remove in [false,true] {
            try "[00:00.10]Bright roan\n[00:03.10]We return".write(to:sidecar,atomically:true,encoding:.utf8)
            await player.loadFolder(root,autoPlay:false)
            let session = LyricsRepairSession(player:player,track:track,settings:settings,transport:transport)
            await session.load(); await session.analyze()
            XCTAssertNil(session.issue)
            for change in try XCTUnwrap(session.review).proposals where change.kind != .unrecognized { session.accept(change) }
            let draft = try session.draft()
            let external = "[00:00.10]External words\n[00:03.10]We return"
            if remove { try FileManager.default.removeItem(at:sidecar) }
            else { try external.write(to:sidecar,atomically:true,encoding:.utf8) }
            await session.save(draft)
            XCTAssertFalse(session.saved); XCTAssertEqual(session.issue,MetadataIOError.changed.localizedDescription)
            XCTAssertEqual(try Data(contentsOf:url),original)
            if remove { XCTAssertFalse(FileManager.default.fileExists(atPath:sidecar.path)) }
            else { XCTAssertEqual(try String(contentsOf:sidecar,encoding:.utf8),external) }
        }
        let calls = await transport.calls; XCTAssertEqual(calls,1,"A second source review reuses the same audio analysis")
    }
}
