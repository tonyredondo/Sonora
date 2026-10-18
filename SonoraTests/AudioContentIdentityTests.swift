import AVFAudio
import SonoraCore
import XCTest
@testable import Sonora

final class AudioContentIdentityTests: XCTestCase {
    func testTagEditsAndRenamingKeepIdentityAcrossWritableFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let folder = try ScopedFolder(root)
        for name in ["fixture.wav","fixture.flac","fixture.mp3","fixture.m4a","fixture.aiff","fixture.alac.m4a"] {
            let original = try XCTUnwrap(Bundle(for:Self.self).url(forResource:(name as NSString).deletingPathExtension,withExtension:(name as NSString).pathExtension))
            let file = root.appendingPathComponent(name); try FileManager.default.copyItem(at:original,to:file)
            let track = try XCTUnwrap(AudioTrack(relativePath:name)), snapshot = try await MetadataService.read(url:file,folder:folder)
            let before = try await AudioContentIdentity.read(track:track,folder:folder,expected:snapshot.fingerprint)
            let updated = try await MetadataService.save(url:file,folder:folder,expected:snapshot.fingerprint,
                patch:MetadataPatch(values:[.artist:"Confirmed artist",.album:"Another edition",.lyrics:"[00:01.00]A line"]))
            let renamed = root.appendingPathComponent("renamed-" + name)
            try FileManager.default.moveItem(at:file,to:renamed)
            let after = try await AudioContentIdentity.read(track:XCTUnwrap(AudioTrack(relativePath:renamed.lastPathComponent)),folder:folder,expected:FileFingerprint(renamed))
            XCTAssertEqual(before,after,name)
            XCTAssertTrue(ConfirmedMetadataRecord.validAudioID(before))
            XCTAssertEqual(updated.values[.album],"Another edition")
        }
    }

    func testOneChangedSampleAndChangedFingerprintCannotReuseIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let folder = try ScopedFolder(root)
        let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
        func wav(changed: Bool) -> Data {
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf:$0) } }
            append(UInt32(36 + 441 * 8)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
            append(UInt16(3)); append(UInt16(1)); append(UInt32(44100)); append(UInt32(44100 * 8)); append(UInt16(8)); append(UInt16(64))
            data.append(Data("data".utf8)); append(UInt32(441 * 8))
            for frame in 0..<441 { append((changed && frame == 220 ? 0.25 + 0.0000000001 : 0.25).bitPattern) }
            return data
        }
        // Write IEEE Float64 directly, so a framework's writer cannot quantize the fixture.
        try wav(changed:false).write(to:a); try wav(changed:true).write(to:b)
        XCTAssertNotEqual(try Data(contentsOf:a),try Data(contentsOf:b))
        let first = try await AudioContentIdentity.read(track:XCTUnwrap(AudioTrack(relativePath:"a.wav")),folder:folder,expected:FileFingerprint(a))
        let second = try await AudioContentIdentity.read(track:XCTUnwrap(AudioTrack(relativePath:"b.wav")),folder:folder,expected:FileFingerprint(b))
        XCTAssertNotEqual(first,second)
        let stale = try FileFingerprint(a)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:30)],ofItemAtPath:a.path)
        do { _ = try await AudioContentIdentity.read(track:XCTUnwrap(AudioTrack(relativePath:"a.wav")),folder:folder,expected:stale); XCTFail("A changed file must be reloaded") }
        catch { XCTAssertEqual(error.localizedDescription,MetadataIOError.changed.localizedDescription) }
    }
}
