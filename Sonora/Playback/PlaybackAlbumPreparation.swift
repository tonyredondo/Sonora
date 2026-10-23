import Foundation
import Observation
import SonoraCore

extension PlaybackController {
    /// Re-arm after catalog edits or indexing, not on the playback ticker.
    func observeAlbumLibrary() {
        withObservationTracking {
            _ = library.state.songs; _ = library.isIndexing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshAlbumPreparation(); self?.observeAlbumLibrary()
            }
        }
    }
    func refreshAlbumPreparation() {
        let preferences = albumPreparationPreferences
        let document = documentAlbum()
        guard !library.isIndexing else { currentAlbum = document; return }
        let collection = library.state
        let queued = Set(queue.tracks.compactMap { libraryID(for: $0) })
        let selected = current.flatMap { libraryID(for: $0) }
        let groups = collection.groups(byAlbum: true)
        let albums = groups.filter { !$0.songIDs.allSatisfy { !queued.contains($0) } }.map { group in
            AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { collection.songs[$0] })
        }
        currentAlbum = albums.first { $0.songs.contains { $0.id == selected } } ?? document
        let ordered = albums.sorted { $0.id == currentAlbum?.id && $1.id != currentAlbum?.id }
        albumInterpretations.update(ordered, preferences: preferences) { [weak self] album, character in
            guard let self else { throw CancellationError() }
            return try await collectAlbum(album, character: character)
        }
    }
    /// An external file can carry a complete saved album reading. Expose that
    /// metadata without indexing its parent or generating an album from one song.
    private func documentAlbum() -> AlbumPreparationRequest? {
        guard let track = current, let source = track.sourceID, let details = currentDetails,
              (try? folderAccess(for: track).documentURL) != nil,
              let album = details.tags[.album], !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let song = CollectionSong(sourceID: source, relativePath: track.relativePath, tags: details.tags,
                                  duration: details.duration, modified: details.fingerprint?.modified)
        return AlbumPreparationRequest(document: song)
    }
    /// Resolve every security scope before the first suspension. CUE tracks keep
    /// their own title and sliced lyrics even when they share an audio file.
    func collectAlbum(_ album: AlbumPreparationRequest, character: Bool) async throws -> AlbumInterpretationInput {
        guard album.songs.count <= 100 else {
            throw MusicTextError.invalid("Este álbum supera el límite de 100 canciones. No se ha recortado su contenido.")
        }
        let items = try album.songs.map { song -> (CollectionSong, AudioTrack, ScopedFolder) in
            guard let track = song.audioTrack else { throw MetadataLookupError.invalidSearch }
            return (song, track, try folderAccess(for: track))
        }
        var tracks: [AlbumInterpretationInput.Track] = []
        for (song, track, folder) in items {
            let snapshot = try await MetadataService.read(url: track.url(in: folder.url), folder: folder)
            let lyrics = try await CoordinatedAudioRead.read(track: track, folder: folder, expected: snapshot.fingerprint) { url, coordinator in
                let document = LyricsDocument(text: LyricsSource.read(for: url, embedded: snapshot.values[.lyrics] ?? "", coordinator: coordinator).text)
                guard let cue = track.cue else { return document }
                return document.sliced(from: cue.startSeconds, duration: track.duration(in: snapshot.duration))
            }
            do {
                _ = try await audioCharacter.load(track: track, folder: folder, expected: snapshot.fingerprint,
                    preparedAudio: musicTools.summary(for: track, folder: folder), cachedOnly: !character)
            } catch {
                // Missing cached tags are allowed when their automatic preparation
                // is disabled. An enabled analysis must finish before the album.
                if character { throw error }
            }
            let context = interpretationContext(for: track, folder: folder, values: snapshot.values, expected: snapshot.fingerprint)
            tracks.append(.init(context: context, lyrics: lyrics.lines.map(\.text).joined(separator: "\n"),
                                genre: track.tags(overriding: snapshot.values)[.genre] ?? song.tags[.genre] ?? ""))
        }
        return AlbumInterpretationInput(title: album.title, artist: album.artist, tracks: tracks)
    }
    func refreshAlbum(_ album: AlbumPreparationRequest, language: String, character: Bool) async throws {
        _ = try await albumInterpretations.load(album, language: language, character: character, refresh: true) { [weak self] album, character in
            guard let self else { throw CancellationError() }
            return try await collectAlbum(album, character: character)
        }
    }
}
