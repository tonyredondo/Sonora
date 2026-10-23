import Foundation
import SonoraCore

extension PlaybackController {
    /// File readers are scoped to this player's library. Both explicit sheets and automatic
    /// preparation use the same fallback, including with no configured server.
    func configurePortableInterpretations() {
        lyricInterpretations.readEmbedded = { [weak self] document, language, context in
            guard let self else { return nil }
            let candidates = library.state.songs.values.filter { song in
                let identity = LyricsInterpretationContext(title: song.title, artist: song.tags[.artist] ?? "", album: song.tags[.album] ?? "")
                return identity.title == context.title && identity.artist == context.artist && identity.album == context.album
            }.compactMap(\.audioTrack)
            let tracks = [current].compactMap { $0 } + candidates
            var seen: Set<String> = []
            for track in tracks where URL(fileURLWithPath: track.relativePath).pathExtension.lowercased() == "mp3" && seen.insert(track.id).inserted {
                guard !Task.isCancelled, let folder = try? folderAccess(for: track),
                      let snapshot = try? await MetadataService.read(url: track.url(in: folder.url), folder: folder),
                      let saved = snapshot.portableInterpretations.songs[language],
                      saved.matches(document, language: language, context: context),
                      let actual = try? await portableDocument(track, folder: folder, snapshot: snapshot) else { continue }
                let actualContext = interpretationContext(for: track, folder: folder, values: snapshot.values, expected: snapshot.fingerprint)
                guard saved.matches(actual, language: language, context: actualContext) else { continue }
                return saved.interpretation
            }
            return nil
        }
        albumInterpretations.readEmbedded = { [weak self] album, language in
            guard let self else { return nil }
            for song in album.songs {
                guard !Task.isCancelled, let track = song.audioTrack, URL(fileURLWithPath: track.relativePath).pathExtension.lowercased() == "mp3",
                      let folder = try? folderAccess(for: track),
                      let snapshot = try? await MetadataService.read(url: track.url(in: folder.url), folder: folder),
                      let saved = snapshot.portableInterpretations.albums[language],
                      saved.language == language, saved.title.trimmingCharacters(in: .whitespacesAndNewlines) == album.title.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let tags = track.tags(overriding: snapshot.values)
                let artist = tags[.albumArtist].flatMap { $0.isEmpty ? nil : $0 } ?? tags[.artist] ?? ""
                guard saved.matches(language: language, title: tags[.album] ?? "", artist: artist) else { continue }
                return saved
            }
            return nil
        }
    }

    private func portableDocument(_ track: AudioTrack, folder: ScopedFolder, snapshot: MetadataSnapshot) async throws -> LyricsDocument {
        try await CoordinatedAudioRead.read(track: track, folder: folder, expected: snapshot.fingerprint) { url, coordinator in
            let document = LyricsDocument(text: LyricsSource.read(for: url, embedded: snapshot.values[.lyrics] ?? "", coordinator: coordinator).text)
            guard let cue = track.cue else { return document }
            return document.sliced(from: cue.startSeconds, duration: track.duration(in: snapshot.duration))
        }
    }

    /// Export reads completed caches only: it never schedules AI, hashing or audio analysis.
    func exportPlaylist(_ id: String, to folder: URL, name: String, format: PlaylistFolderExport.Format,
                        progress: @escaping @Sendable (PlaylistFolderExport.Progress) -> Void = { _ in }) async throws -> URL {
        guard let playlist = library.state.playlists.first(where: { $0.id == id }), !playlist.songIDs.isEmpty else {
            throw MusicTextError.invalid("La playlist está vacía o ya no existe.")
        }
        guard playlist.songIDs.count <= 10_000 else { throw MusicTextError.invalid("La lista supera las 10.000 canciones que admite M3U8.") }
        let collection = library.state, languages = PortableInterpretations.languages.sorted()
        let character = albumPreparationPreferences.character
        let groups = collection.groups(byAlbum: true)
        var readings: [String: PortableInterpretations] = [:], albums: [String: [String: AlbumInterpretationStore.Prepared]] = [:]
        var checkedAlbums: Set<String> = []
        for id in playlist.songIDs {
            try Task.checkCancellation()
            guard let song = collection.songs[id], let track = song.audioTrack else { throw MetadataLookupError.invalidSearch }
            guard format == .mp3 || URL(fileURLWithPath: track.relativePath).pathExtension.lowercased() == "mp3" else { continue }
            let access = try library.access(song.sourceID)
            let snapshot = try await MetadataService.read(url: track.url(in: access.url), folder: access)
            let document = try await portableDocument(track, folder: access, snapshot: snapshot)
            _ = try? await audioCharacter.restore(track: track, folder: access, expected: snapshot.fingerprint)
            let context = interpretationContext(for: track, folder: access, values: snapshot.values, expected: snapshot.fingerprint)
            let albumArtist = snapshot.values[.albumArtist].flatMap { $0.isEmpty ? nil : $0 } ?? context.artist
            var saved = PortableInterpretations(
                songs: snapshot.portableInterpretations.songs.filter { $0.value.matches(document, language: $0.key, context: context) },
                albums: snapshot.portableInterpretations.albums.filter { $0.value.matches(language: $0.key, title: context.album, artist: albumArtist) }
            )
            for language in languages {
                try Task.checkCancellation()
                if let meaning = await lyricInterpretations.cachedResult(document, language: language, context: context) {
                    saved.songs[language] = .init(language: language, title: context.title, artist: context.artist, album: context.album,
                                                 lyricsDigest: PortableInterpretations.lyricsDigest(document), interpretation: meaning)
                }
            }
            if !context.album.isEmpty, let group = groups.first(where: { $0.songIDs.contains(id) }) {
                if checkedAlbums.insert(group.id).inserted {
                    let request = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { collection.songs[$0] })
                    for language in languages {
                        try Task.checkCancellation()
                        if let reading = try await albumInterpretations.cachedResult(request, language: language, character: character) {
                            albums[group.id, default: [:]][language] = reading
                        }
                    }
                }
                for (language, reading) in albums[group.id] ?? [:] where reading.title.trimmingCharacters(in: .whitespacesAndNewlines) == context.album {
                    saved.albums[language] = .init(language: language, title: context.album, artist: albumArtist,
                                                  trackCount: reading.trackCount, missingLyrics: reading.missingLyrics, interpretation: reading.interpretation)
                }
            }
            if !saved.isEmpty { readings[id] = saved }
        }
        return try await PlaylistFolderExport.exportPlaylist(playlist.id, library: library, folder: folder, name: name, format: format,
                                                             interpretations: readings, progress: progress)
    }
}
