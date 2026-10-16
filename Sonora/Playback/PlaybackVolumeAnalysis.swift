import Foundation
import SonoraCore

extension PlaybackController {
    func volumeTargets(for tracks: [AudioTrack]) throws -> [VolumeAnalysisTarget] {
        var seen: Set<String> = []
        return try tracks.compactMap { track in
            let folder = try folderAccess(for: track)
            guard let source = track.sourceID ?? library.sourceID(matching: folder.url) else { throw CocoaError(.fileReadNoPermission) }
            let id = source + "\0" + track.localID
            guard seen.insert(id).inserted else { return nil }
            return VolumeAnalysisTarget(id: id, url: track.url(in: folder.url), folder: folder, cue: track.cue)
        }
    }

    func volumeCandidate(for track: AudioTrack, folder: ScopedFolder, includeAlbum: Bool) -> VolumeAnalysisCandidate? {
        guard let source = track.sourceID ?? library.sourceID(matching: folder.url) else { return nil }
        let id = source + "\0" + track.localID
        var members: [VolumeAnalysisTarget] = []
        if includeAlbum, let albumID = volumeAnalysis.records[id]?.albumID, let album = volumeAnalysis.albums[albumID] {
            for member in album.members.keys {
                guard let song = library.state.songs[member], let track = song.audioTrack,
                      let target = try? volumeTargets(for: [track]).first else { continue }
                members.append(target)
            }
        }
        // The immutable collection snapshot is checked on the I/O worker, together
        // with each member's fingerprint. No library-wide search runs on MainActor.
        return volumeAnalysis.candidate(for: id, members: members, librarySongs: includeAlbum ? library.state.songs : nil)
    }

    func saveVolumeTags(_ targets: [VolumeAnalysisTarget], progress: @escaping @MainActor (Int) -> Void) async -> MetadataBatchResult {
        await metadataTransaction { _ in
            var written = 0, failures: [MetadataWriteFailure] = []
            for (index, target) in targets.enumerated() {
                if Task.isCancelled {
                    failures.append(contentsOf: targets[index...].map { .init(id: $0.id, filename: $0.url.lastPathComponent, message: "Cancelado; no se ha modificado.") }); break
                }
                do {
                    guard target.cue == nil else { throw MusicTextError.invalid("El análisis CUE se guarda solo en Sonora para conservar las etiquetas del archivo compartido.") }
                    guard let song = library.state.songs[target.id], let track = song.audioTrack,
                          let candidate = volumeCandidate(for: track, folder: target.folder, includeAlbum: true),
                          let value = try await VolumeAnalysisService.cachedGain(candidate, url: target.url) else { throw MetadataIOError.changed }
                    let saved = try await MetadataService.save(url: target.url, folder: target.folder, expected: candidate.track.fingerprint,
                                                               patch: MetadataPatch(), replayGain: value)
                    try volumeAnalysis.rebind(target.id, from: candidate.track.fingerprint, to: saved.fingerprint)
                    await library.refresh(track: track, source: song.sourceID, folder: target.folder)
                    written += 1
                } catch { failures.append(.init(id: target.id, filename: target.url.lastPathComponent, message: error.localizedDescription)) }
                progress(index + 1)
            }
            return MetadataBatchResult(written: written, failures: failures)
        }
    }
}
