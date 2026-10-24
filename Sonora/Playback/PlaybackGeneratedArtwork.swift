import Foundation
import ImageIO
import SonoraCore

extension PlaybackController {
    func enqueueGeneratedArtwork(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint,
                                 preferences: QueuePreparationPreferences) {
        guard let generatedArtwork else { return }
        let owner = GeneratedArtworkStore.owner(track, folder: folder)
        generatedArtwork.enqueue(owner: owner, fingerprint: expected, enabled: preferences.artwork,
            allowed: { [weak self] in self?.albumPreparationPreferences.artwork == true }) { [weak self] in
            guard let self else { throw CancellationError() }
            let snapshot = try await MetadataService.read(url: track.url(in: folder.url), folder: folder)
            guard snapshot.fingerprint == expected else { throw MetadataIOError.changed }
            let realCover = try await CoordinatedAudioRead.read(track: track, folder: folder, expected: expected) { url, _ in
                Self.hasArtwork(snapshot.artwork) || Self.hasArtwork(LocalArtwork.data(for: url))
            }
            guard !realCover else { return nil }
            // Indexing publishes complete album membership at its boundary.
            // This wait belongs to artwork preparation, never the decoder.
            await library.waitForIndexing()
            let collection = library.state
            let songID = libraryID(for: track)
            let group = collection.groups(byAlbum: true).first { $0.songIDs.contains(songID ?? "") }
            let tags = track.tags(overriding: snapshot.values)
            let album: AlbumPreparationRequest?
            if let group {
                album = AlbumPreparationRequest(group: group, songs: group.songIDs.compactMap { collection.songs[$0] })
            } else if let source = track.sourceID, let title = tags[.album], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                album = AlbumPreparationRequest(document: CollectionSong(sourceID: source, relativePath: track.relativePath,
                    tags: tags, duration: snapshot.duration, modified: expected.modified))
            } else { album = nil }
            var description = ""
            if let album {
                // A file grant can restore an embedded album reading, but cannot
                // fabricate complete album membership from neighboring files.
                let cachedOnly = !preferences.meaning || folder.documentURL != nil
                if let reading = try? await albumInterpretations.load(album, language: preferences.meaningLanguage,
                    character: preferences.character, cachedOnly: cachedOnly, collect: { [weak self] album, character in
                        guard let self else { throw CancellationError() }
                        return try await collectAlbum(album, character: character)
                    }) {
                    description = reading.interpretation.explanation
                }
            }
            let context = interpretationContext(for: track, folder: folder, values: snapshot.values, expected: expected)
            return GeneratedArtworkInput(title: context.title, artist: context.artist, album: context.album,
                albumDescription: description, genre: tags[.genre] ?? "", styles: context.styles, moods: context.moods)
        }
    }
    private nonisolated static func hasArtwork(_ data: Data?) -> Bool {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1] as CFDictionary) != nil
    }
}
