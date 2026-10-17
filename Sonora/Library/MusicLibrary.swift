import CryptoKit
import Foundation
import ImageIO
import Observation
import SonoraCore
import UniformTypeIdentifiers

@MainActor @Observable
final class MusicLibrary {
    private(set) var state: MusicCollection
    private(set) var allSongs: [CollectionSong] = []
    private(set) var albums: [CollectionGroup] = []
    private(set) var artists: [CollectionGroup] = []
    private(set) var isIndexing = false
    private(set) var progress = ""
    var issue: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let artworkDirectory: URL
    @ObservationIgnored private var sourceURLs: [String: URL] = [:]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var indexRequests: [IndexRequest] = []
    @ObservationIgnored private var activeIndexSource: String?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    @ObservationIgnored private var indexID = UUID()
    @ObservationIgnored private var canPersist = true
    var needsReset: Bool { !canPersist }
    @ObservationIgnored private var metadataRevisions: [String: UUID] = [:]
    private struct IndexRequest {
        let source: String
        let folder: ScopedFolder
        let tracks: [AudioTrack]
    }

    init(defaults: UserDefaults, artworkDirectory: URL? = nil) {
        self.defaults = defaults
        self.artworkDirectory = artworkDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SonoraArtwork")
        do {
            state = try defaults.data(forKey: "musicCollection").map { try JSONDecoder().decode(MusicCollection.self, from: $0) } ?? MusicCollection()
        } catch {
            state = MusicCollection(); canPersist = false
            issue = "No se pudo leer la biblioteca guardada. Puedes restablecerla sin borrar los archivos de música."
        }
        rebuild()
        let unfinished = state.sources.compactMap { source -> (String, [AudioTrack])? in
            let tracks = state.songs.values.filter { $0.sourceID == source.id && $0.modified == nil }.compactMap(\.audioTrack)
            return tracks.isEmpty ? nil : (source.id, tracks)
        }
        if !unfinished.isEmpty {
            resumeTask = Task { [weak self] in
                guard let self else { return }
                for (source, tracks) in unfinished {
                    guard !Task.isCancelled else { return }
                    guard state.sources.contains(where: { $0.id == source }) else { continue }
                    do { startIndex(source: source, folder: try access(source), tracks: tracks) }
                    catch { issue = "Vuelve a abrir una carpeta para completar su información: \(error.localizedDescription)" }
                }
            }
        }
    }
    isolated deinit { indexTask?.cancel(); resumeTask?.cancel(); derivedTask?.cancel() }
    func cancelIndexing() {
        resumeTask?.cancel(); indexRequests = []
        indexTask?.cancel(); indexID = UUID(); activeIndexSource = nil; isIndexing = false; progress = ""
    }

    func sourceURL(_ id: String) throws -> URL {
        if let cached = sourceURLs[id] { return cached }
        guard let source = state.sources.first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoPermission) }
        let url = try resolveBookmark(source.bookmark)
        sourceURLs[id] = url
        return url
    }
    private func resolveBookmark(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    func access(_ id: String) throws -> ScopedFolder { try ScopedFolder(sourceURL(id)) }
    func sourceID(matching url: URL) -> String? {
        state.sources.first { (try? sourceURL($0.id).standardizedFileURL) == url.standardizedFileURL }?.id
    }

    @discardableResult
    func register(_ folder: ScopedFolder, tracks: [AudioTrack], name: String? = nil) throws -> String {
        let url = folder.url.standardizedFileURL
        let matchingID = sourceID(matching: url)
        let previous = state.sources.first { $0.id == matchingID }
        let source = CollectionSource(id: previous?.id ?? UUID().uuidString, name: name ?? previous?.name ?? url.lastPathComponent, bookmark: try folder.bookmark())
        // Use the saved grant immediately, just as after relaunch. Normalized
        // paths are for matching; file access uses the bookmark's scoped URL.
        let access = try ScopedFolder(resolveBookmark(source.bookmark))
        if let index = state.sources.firstIndex(where: { $0.id == source.id }) { state.sources[index] = source }
        else { state.sources.append(source) }
        sourceURLs[source.id] = access.url
        let segments = Dictionary(grouping: tracks.filter { $0.cue != nil }, by: \.relativePath)
        var replacements: [String: [String]] = [:]
        for song in state.songs.values where song.sourceID == source.id && song.cue == nil {
            if let songs = segments[song.relativePath] { replacements[song.id] = songs.map { $0.withSource(source.id).id } }
        }
        let paths = Set(tracks.map(\.localID))
        state.songs = state.songs.filter { $0.value.sourceID != source.id || paths.contains($0.value.audioTrack?.localID ?? "") }
        let missing = tracks.map { CollectionSong(sourceID: source.id, relativePath: $0.relativePath, tags: $0.cue?.tags ?? [:], cue: $0.cue) }.filter { state.songs[$0.id] == nil }
        state.upsert(missing); state.replaceSongReferences(replacements); persist(); rebuild()
        startIndex(source: source.id, folder: access, tracks: tracks)
        return source.id
    }

    private func startIndex(source: String, folder: ScopedFolder, tracks: [AudioTrack]) {
        indexRequests.removeAll { $0.source == source }
        if activeIndexSource == source {
            indexTask?.cancel(); indexID = UUID(); activeIndexSource = nil; isIndexing = false
        }
        indexRequests.append(IndexRequest(source: source, folder: folder, tracks: tracks))
        startNextIndex()
    }
    private func startNextIndex() {
        guard !isIndexing, !indexRequests.isEmpty else { return }
        let request = indexRequests.removeFirst()
        let source = request.source, folder = request.folder, tracks = request.tracks
        let token = UUID(); indexID = token; activeIndexSource = source; isIndexing = true
        indexTask = Task { [weak self] in
            guard let self else { return }
            var pending: [(CollectionSong, UUID?)] = [], failures = 0, skipped = 0
            var sidecarKeys: [URL: String] = [:], checkedSidecars: Set<URL> = []
            @MainActor func commit() {
                self.state.upsert(pending.filter { self.metadataRevisions[$0.0.id] == $0.1 }.map(\.0))
                pending.removeAll(keepingCapacity: true)
            }
            for (index, track) in tracks.enumerated() {
                guard !Task.isCancelled, indexID == token else { return }
                progress = "\(folder.url.lastPathComponent) · \(index + 1) / \(tracks.count)"
                let url = track.url(in: folder.url)
                let songID = source + "\0" + track.localID, revision = metadataRevisions[source + "\0" + track.localID]
                let resource = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if resource?.isUbiquitousItem == true && resource?.ubiquitousItemDownloadingStatus != .current && resource?.ubiquitousItemDownloadingStatus != .downloaded {
                    skipped += 1; continue
                }
                do {
                    let snapshot = try await MetadataService.read(url: url, folder: folder)
                    try Task.checkCancellation()
                    let directory = url.deletingLastPathComponent()
                    let key: String?
                    if snapshot.artwork != nil { key = try await storeArtwork(snapshot.artwork) }
                    else if checkedSidecars.contains(directory) { key = sidecarKeys[directory] }
                    else {
                        let data = await Task.detached(priority: .utility) { LocalArtwork.data(in: directory) }.value
                        key = try await storeArtwork(data)
                        if checkedSidecars.count >= 256 { checkedSidecars = []; sidecarKeys = [:] }
                        checkedSidecars.insert(directory); sidecarKeys[directory] = key
                    }
                    try Task.checkCancellation(); guard indexID == token else { return }
                    if metadataRevisions[songID] == revision {
                        pending.append((CollectionSong(sourceID: source, relativePath: track.relativePath, tags: track.tags(overriding: snapshot.values), duration: track.duration(in: snapshot.duration),
                                                       format: snapshot.fileDescription, artworkKey: key, modified: snapshot.fingerprint.modified, cue: track.cue), revision))
                    }
                    if pending.count >= 256 { commit() }
                } catch is CancellationError { return }
                catch { failures += 1 }
            }
            guard indexID == token, !Task.isCancelled else { return }
            commit(); persist(); rebuild(); isIndexing = false
            activeIndexSource = nil
            progress = skipped > 0 ? "\(skipped) archivos en iCloud se analizarán cuando estén descargados." : ""
            if failures > 0 { issue = "No se pudo leer la información de \(failures) archivos. Sus referencias siguen en la biblioteca." }
            startNextIndex()
        }
    }

    func update(_ details: TrackDetails, source: String, track: AudioTrack) {
        let id = source + "\0" + track.localID
        let old = state.songs[id]
        let value = CollectionSong(sourceID: source, relativePath: track.relativePath, tags: details.tags, duration: details.duration, format: details.format,
                                   artworkKey: old?.artworkKey, modified: old?.modified, cue: track.cue)
        guard value != old else { return }
        state.upsert([value]); persist(); rebuild()
    }
    func refresh(track: AudioTrack, source: String, folder: ScopedFolder) async {
        metadataRevisions[source + "\0" + track.relativePath] = UUID()
        do {
            let value = try await MetadataService.read(url: track.url(in: folder.url), folder: folder)
            let directory = track.url(in: folder.url).deletingLastPathComponent()
            let data: Data?
            if let embedded = value.artwork { data = embedded }
            else { data = await Task.detached(priority: .utility) { LocalArtwork.data(in: directory) }.value }
            let key = try await storeArtwork(data)
            state.upsert([CollectionSong(sourceID: source, relativePath: track.relativePath, tags: value.values, duration: value.duration,
                                         format: value.fileDescription, artworkKey: key, modified: value.fingerprint.modified)])
            persist(); rebuild()
        } catch { issue = "El archivo se guardó, pero no se pudo actualizar su información en la biblioteca: \(error.localizedDescription)" }
    }
    private func storeArtwork(_ data: Data?) async throws -> String? {
        guard let data else { return nil }
        let root = artworkDirectory
        return try await Task.detached(priority: .utility) {
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".jpg"
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(key).path) { return key }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (output as Data).write(to: root.appendingPathComponent(key), options: .atomic)
            return key
        }.value
    }
    func toggleFavorite(_ id: String) { state.toggleFavorite(id); persist() }
    func toggleAlbum(_ id: String) { if !state.favoriteAlbums.insert(id).inserted { state.favoriteAlbums.remove(id) }; persist() }
    func toggleArtist(_ id: String) { if !state.favoriteArtists.insert(id).inserted { state.favoriteArtists.remove(id) }; persist() }
    func createPlaylist(_ name: String) -> String? { let id = state.createPlaylist(name); persist(); return id }
    func add(_ ids: [String], to playlist: String) { state.add(ids, to: playlist); persist() }
    func recordPlayed(_ id: String) { state.recordPlayed(id); persist() }
    func move(in playlist: String, from offsets: IndexSet, to destination: Int) { state.move(in: playlist, from: offsets, to: destination); persist() }
    func remove(from playlist: String, at offsets: IndexSet) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        for offset in offsets.reversed() where state.playlists[index].songIDs.indices.contains(offset) { state.playlists[index].songIDs.remove(at: offset) }
        persist()
    }
    func renamePlaylist(_ id: String, name: String) {
        guard let index = state.playlists.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.playlists[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); persist()
    }
    func deletePlaylist(_ id: String) { state.playlists.removeAll { $0.id == id }; persist() }
    func clearHistory() { state.history = []; persist() }
    func forgetSource(_ id: String) {
        indexRequests.removeAll { $0.source == id }
        if activeIndexSource == id {
            indexTask?.cancel(); indexID = UUID(); activeIndexSource = nil; isIndexing = false
        }
        state.sources.removeAll { $0.id == id }; sourceURLs.removeValue(forKey: id)
        let ids = Set(state.songs.values.filter { $0.sourceID == id }.map(\.id))
        for id in ids { state.songs.removeValue(forKey: id); state.favorites.remove(id) }
        for index in state.playlists.indices { state.playlists[index].songIDs.removeAll { ids.contains($0) } }
        state.history.removeAll { ids.contains($0.songID) }; persist(); rebuild(); startNextIndex()
    }
    func reset() { cancelIndexing(); state = MusicCollection(); sourceURLs = [:]; metadataRevisions = [:]; canPersist = true; issue = nil; persist(); rebuild() }
    func persist() {
        guard canPersist else { return }
        do { defaults.set(try JSONEncoder().encode(state), forKey: "musicCollection") }
        catch { issue = "No se pudo guardar la biblioteca: \(error.localizedDescription)" }
    }
    private func rebuild() {
        derivedTask?.cancel()
        derivedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            let snapshot = state
            let values = await Task.detached(priority: .utility) { (snapshot.sortedSongs(), snapshot.groups(byAlbum: true), snapshot.groups(byAlbum: false)) }.value
            guard !Task.isCancelled else { return }
            allSongs = values.0; albums = values.1; artists = values.2
        }
    }
}
