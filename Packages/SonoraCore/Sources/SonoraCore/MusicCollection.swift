import Foundation

public struct CollectionSource: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var bookmark: Data
    public init(id: String = UUID().uuidString, name: String, bookmark: Data) { self.id = id; self.name = name; self.bookmark = bookmark }
}

public struct CollectionSong: Codable, Identifiable, Equatable, Sendable {
    public let sourceID: String
    public let relativePath: String
    public let cue: CueSegment?
    public var tags: [MetadataField: String]
    public var duration: Double
    public var format: String
    public var artworkKey: String?
    public var modified: Date?
    public var id: String { sourceID + "\0" + (audioTrack?.localID ?? relativePath) }
    public var audioTrack: AudioTrack? { AudioTrack(relativePath: relativePath, sourceID: sourceID, cue: cue) }
    public init(sourceID: String, relativePath: String, tags: [MetadataField: String] = [:], duration: Double = 0, format: String = "", artworkKey: String? = nil, modified: Date? = nil, cue: CueSegment? = nil) {
        self.cue = cue
        self.sourceID = sourceID; self.relativePath = relativePath; self.tags = tags.filter { $0.key != .lyrics }
        self.duration = duration.isFinite ? max(0, duration) : 0; self.format = format; self.artworkKey = artworkKey; self.modified = modified
    }
    public var title: String { nonempty(.title) ?? ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
    public var artist: String { nonempty(.artist) ?? "Artista desconocido" }
    public var album: String { nonempty(.album) ?? "Álbum desconocido" }
    public var albumArtist: String { nonempty(.albumArtist) ?? artist }
    public var artistID: String { artist.searchKey }
    public var albumID: String {
        if nonempty(.album) == nil { return "folder\0" + sourceID + "\0" + (relativePath as NSString).deletingLastPathComponent }
        return albumArtist.searchKey + "\0" + album.searchKey
    }
    private func nonempty(_ key: MetadataField) -> String? { tags[key].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
    public func matches(_ query: String) -> Bool {
        let text = ([title, artist, album, relativePath] + tags.filter { $0.key != .lyrics }.map(\.value)).joined(separator: " ").searchKey
        return query.searchKey.split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }
}

public struct CollectionGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let songIDs: [String]
}
public struct MusicPlaylist: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var songIDs: [String]
}
public struct ListeningEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let songID: String
    public let date: Date
}

public struct MusicCollection: Codable, Equatable, Sendable {
    public var sources: [CollectionSource] = []
    public var songs: [String: CollectionSong] = [:]
    public var favorites: Set<String> = []
    public var favoriteAlbums: Set<String> = []
    public var favoriteArtists: Set<String> = []
    public var playlists: [MusicPlaylist] = []
    public var history: [ListeningEvent] = []
    public init() {}
    public mutating func upsert(_ values: [CollectionSong]) {
        let available = Set(sources.map(\.id))
        for song in values where available.contains(song.sourceID) && song.audioTrack != nil { songs[song.id] = song }
    }
    public mutating func toggleFavorite(_ id: String) { if !favorites.insert(id).inserted { favorites.remove(id) } }
    @discardableResult public mutating func createPlaylist(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let id = UUID().uuidString; playlists.append(MusicPlaylist(id: id, name: name, songIDs: [])); return id
    }
    public mutating func add(_ songIDs: [String], to playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var seen = Set(playlists[index].songIDs)
        playlists[index].songIDs.append(contentsOf: songIDs.filter { songs[$0] != nil && seen.insert($0).inserted })
    }
    public mutating func move(in playlistID: String, from offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var ids = playlists[index].songIDs
        let offsets = offsets.filter { ids.indices.contains($0) }, moving = offsets.map { ids[$0] }
        for value in offsets.reversed() { ids.remove(at: value) }
        ids.insert(contentsOf: moving, at: min(ids.count, max(0, destination - offsets.filter { $0 < destination }.count)))
        playlists[index].songIDs = ids
    }
    public mutating func recordPlayed(_ songID: String, at date: Date = Date()) {
        guard songs[songID] != nil else { return }
        history.removeAll { $0.songID == songID }
        history.insert(ListeningEvent(id: UUID().uuidString, songID: songID, date: date), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }
    /// Expand a former album-image reference after it gains CUE songs. A historical
    /// whole-image event uses its first song; its date and event identity survive.
    public mutating func replaceSongReferences(_ replacements: [String: [String]]) {
        let mapping = replacements.filter { !$0.value.isEmpty && $0.value.allSatisfy { songs[$0] != nil } }
        guard !mapping.isEmpty else { return }
        favorites = Set(favorites.flatMap { mapping[$0] ?? [$0] })
        for index in playlists.indices {
            var seen: Set<String> = []
            playlists[index].songIDs = playlists[index].songIDs.flatMap { mapping[$0] ?? [$0] }.filter { seen.insert($0).inserted }
        }
        var seen: Set<String> = []
        history = history.compactMap { event in
            let song = mapping[event.songID]?.first ?? event.songID
            guard seen.insert(song).inserted else { return nil }
            return ListeningEvent(id: event.id, songID: song, date: event.date)
        }
    }
    public func groups(byAlbum: Bool) -> [CollectionGroup] {
        let values = Dictionary(grouping: songs.values, by: { byAlbum ? $0.albumID : $0.artistID })
        return values.compactMap { key, songs in
            let sorted = songs.sorted { a, b in
                if !byAlbum && a.album != b.album { return a.album.localizedStandardCompare(b.album) == .orderedAscending }
                let ad = Int(a.tags[.discNumber] ?? "") ?? 1, bd = Int(b.tags[.discNumber] ?? "") ?? 1
                if ad != bd { return ad < bd }
                let at = Int(a.tags[.trackNumber] ?? "") ?? Int.max, bt = Int(b.tags[.trackNumber] ?? "") ?? Int.max
                if at != bt { return at < bt }
                return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
            }
            guard let first = sorted.first else { return nil }
            return CollectionGroup(id: key, title: byAlbum ? first.album : first.artist, subtitle: byAlbum ? first.albumArtist : "\(songs.count) canciones", songIDs: sorted.map(\.id))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func sortedSongs(_ ids: [String]? = nil) -> [CollectionSong] {
        (ids.map { $0.compactMap { songs[$0] } } ?? Array(songs.values)).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private extension String {
    var searchKey: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
