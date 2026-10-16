import Foundation
import Observation
import SonoraCore

struct VolumeTrackMeasurement: Codable, Equatable, Sendable {
    var fingerprint: FileFingerprint
    let gain: Double
    let peak: Double
    let measuredAt: Date
    var albumID: String? = nil
    var isValid: Bool { gain.isFinite && peak.isFinite && peak >= 0 }
}
struct VolumeAlbumMeasurement: Codable, Equatable, Sendable {
    let id: String
    var members: [String: FileFingerprint]
    let gain: Double
    let peak: Double
    var isValid: Bool { !members.isEmpty && gain.isFinite && peak.isFinite && peak >= 0 }
}
struct VolumeAnalysisBatch: Sendable {
    let records: [String: VolumeTrackMeasurement]
    let album: VolumeAlbumMeasurement?
}
struct VolumeAnalysisTarget: Sendable {
    let id: String
    let url: URL
    let folder: ScopedFolder
    var cue: CueSegment? = nil
}

/// Contains references and their scopes, never PCM. Only the I/O worker checks freshness.
struct VolumeAnalysisCandidate: Sendable {
    let id: String
    let track: VolumeTrackMeasurement
    let album: VolumeAlbumMeasurement?
    let members: [VolumeAnalysisTarget]
    let librarySongs: [String: CollectionSong]?

    func validated(fingerprint: FileFingerprint) -> ReplayGain? {
        guard track.isValid, track.fingerprint == fingerprint else { return nil }
        var value = ReplayGain(trackGain: track.gain, trackPeak: track.peak)
        let matchesLibrary: Bool
        if let librarySongs, let album, let groupID = librarySongs[id]?.albumID {
            matchesLibrary = Set(librarySongs.values.filter { $0.albumID == groupID }.map(\.id)) == Set(album.members.keys)
        } else { matchesLibrary = librarySongs == nil }
        if let album, album.isValid, matchesLibrary, Set(members.map(\.id)) == Set(album.members.keys),
           members.allSatisfy({ (try? FileFingerprint($0.url)) == album.members[$0.id] }) {
            value.albumGain = album.gain; value.albumPeak = album.peak
        }
        return value
    }
}

@MainActor @Observable
final class VolumeAnalysisStore {
    private struct Archive: Codable {
        var records: [String: VolumeTrackMeasurement] = [:]
        var albums: [String: VolumeAlbumMeasurement] = [:]
    }
    private(set) var records: [String: VolumeTrackMeasurement] = [:]
    private(set) var albums: [String: VolumeAlbumMeasurement] = [:]
    private(set) var issue: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        do {
            let archive = try defaults.data(forKey: "volumeAnalysis").map { try JSONDecoder().decode(Archive.self, from: $0) } ?? Archive()
            guard archive.records.values.allSatisfy(\.isValid), archive.albums.values.allSatisfy(\.isValid) else { throw CocoaError(.fileReadCorruptFile) }
            records = archive.records; albums = archive.albums
        } catch { issue = "No se pudieron leer los análisis guardados. Puedes restablecerlos sin modificar tu música." }
    }
    func candidate(for id: String, members: [VolumeAnalysisTarget] = [], librarySongs: [String: CollectionSong]? = nil) -> VolumeAnalysisCandidate? {
        guard let track = records[id] else { return nil }
        return VolumeAnalysisCandidate(id: id, track: track, album: track.albumID.flatMap { albums[$0] }, members: members, librarySongs: librarySongs)
    }
    func record(_ batch: VolumeAnalysisBatch) throws {
        guard issue == nil else { throw CocoaError(.fileWriteNoPermission) }
        guard batch.records.values.allSatisfy(\.isValid), batch.album?.isValid != false else { throw CocoaError(.fileReadCorruptFile) }
        if let album = batch.album {
            guard album.members.allSatisfy({ (batch.records[$0.key] ?? records[$0.key])?.fingerprint == $0.value }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        for (id, value) in batch.records {
            var value = value
            if let previous = records[id], previous.fingerprint == value.fingerprint, value.albumID == nil { value.albumID = previous.albumID }
            records[id] = value
        }
        if let album = batch.album {
            albums[album.id] = album
            for id in album.members.keys { records[id]?.albumID = album.id }
        }
        let referenced = Set(records.values.compactMap(\.albumID))
        albums = albums.filter { referenced.contains($0.key) }
        try persist()
    }
    /// Our verified tag-only writes preserve audio; update all members of a measured album.
    func rebind(_ id: String, from expected: FileFingerprint, to updated: FileFingerprint) throws {
        guard records[id]?.fingerprint == expected else { return }
        records[id]?.fingerprint = updated
        for key in Array(albums.keys) where albums[key]?.members[id] == expected { albums[key]?.members[id] = updated }
        try persist()
    }
    func forget(_ ids: Set<String>) {
        for id in ids { records.removeValue(forKey: id) }
        albums = albums.filter { Set($0.value.members.keys).isDisjoint(with: ids) }
        try? persist()
    }
    func reset() { records = [:]; albums = [:]; issue = nil; defaults.removeObject(forKey: "volumeAnalysis") }
    private func persist() throws {
        guard issue == nil else { throw CocoaError(.fileWriteNoPermission) }
        defaults.set(try JSONEncoder().encode(Archive(records: records, albums: albums)), forKey: "volumeAnalysis")
    }
}
