import Foundation
import SonoraCore

struct PlaylistImportDocument: Sendable {
    let url: URL
    let content: M3UPlaylist
    var name: String { url.deletingPathExtension().lastPathComponent }
}
struct PlaylistImportReport: Sendable {
    let playlistID: String
    let imported: Int
    let problems: [PlaylistProblem]
}

enum PlaylistExchange {
    static func read(_ url: URL) async throws -> PlaylistImportDocument {
        try await perform { job in
            let access = try ScopedFolder(url)
            let data = try MusicText.read(access.url, coordinator: job.coordinator)
            return try PlaylistImportDocument(url: url, content: M3UPlaylist.decode(data, utf8Only: url.pathExtension.lowercased() == "m3u8"))
        }
    }

    @MainActor static func importPlaylist(_ document: PlaylistImportDocument, folder url: URL, library: MusicLibrary) async throws -> PlaylistImportReport {
        guard !library.needsReset else { throw MusicTextError.invalid("Restablece la biblioteca antes de importar playlists.") }
        let folder = try ScopedFolder(url)
        let resolved = try await perform { job in
            let scanned = try FolderScanner.scan(folder.url, isCancelled: { Task.isCancelled }, readText: { try MusicText.read($0, coordinator: job.coordinator) })
            let files = Dictionary(grouping: scanned, by: \.relativePath)
            let sheets = Dictionary(grouping: scanned.filter { $0.cue != nil }, by: { $0.cue!.sheetPath })
            var selected: [AudioTrack] = [], seen: Set<String> = [], problems = document.content.problems
            for (index, entry) in document.content.entries.enumerated() {
                try Task.checkCancellation()
                do {
                    let path = try M3UPlaylist.relativePath(entry.path, playlist: document.url, root: folder.url)
                    guard var matches = files[path] ?? sheets[path] else { throw MusicTextError.invalid("No se encuentra el audio o su formato no está admitido.") }
                    if entry.start != nil || entry.end != nil {
                        matches = matches.filter { track in
                            guard let cue = track.cue, abs(cue.startSeconds - (entry.start ?? 0)) < 0.0001 else { return false }
                            return entry.end.map { end in cue.endSeconds.map { abs($0 - end) < 0.0001 } == true } ?? (cue.endSeconds == nil)
                        }
                        guard !matches.isEmpty else { throw MusicTextError.invalid("Los límites de tiempo no coinciden con una pista CUE de esta carpeta.") }
                    }
                    for track in matches {
                        if seen.insert(track.localID).inserted { selected.append(track) }
                        else { problems.append(.init(line: 10_000 + index, path: entry.path, reason: "Entrada repetida: se conserva su primera aparición.")) }
                    }
                } catch { problems.append(.init(line: 10_000 + index, path: entry.path, reason: error.localizedDescription)) }
            }
            guard !selected.isEmpty else { throw MusicTextError.invalid("No se ha encontrado ninguna canción de la lista en la carpeta elegida. Comprueba sus rutas relativas.") }
            return (scanned, selected, problems)
        }
        try Task.checkCancellation()
        let source = try library.register(folder, tracks: resolved.0)
        guard let id = library.createPlaylist(document.name) else { throw MusicTextError.invalid("La playlist necesita un nombre.") }
        library.add(resolved.1.map { $0.withSource(source).id }, to: id)
        return PlaylistImportReport(playlistID: id, imported: resolved.1.count, problems: resolved.2)
    }

    @MainActor static func exportPlaylist(_ id: String, library: MusicLibrary, folder url: URL, name: String, legacy: Bool) async throws -> URL {
        guard let playlist = library.state.playlists.first(where: { $0.id == id }), !playlist.songIDs.isEmpty else { throw MusicTextError.invalid("La playlist está vacía o ya no existe.") }
        let songs = try playlist.songIDs.map { id in
            guard let song = library.state.songs[id], song.audioTrack != nil else { throw MusicTextError.invalid("Una canción ya no está en la biblioteca.") }
            return song
        }
        let scopes = try Dictionary(uniqueKeysWithValues: Set(songs.map(\.sourceID)).map { ($0, try library.access($0)) })
        let access = try ScopedFolder(url)
        return try await perform { job in
            defer { withExtendedLifetime(scopes) {} }
            let root = access.url.standardizedFileURL.resolvingSymlinksInPath()
            let entries = try songs.map { song -> M3UEntry in
                try Task.checkCancellation()
                guard let track = song.audioTrack, let source = scopes[song.sourceID] else { throw CocoaError(.fileReadNoPermission) }
                let target = track.url(in: source.url).standardizedFileURL.resolvingSymlinksInPath()
                let base = source.url.standardizedFileURL.resolvingSymlinksInPath().path
                guard target.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { throw CocoaError(.fileReadNoPermission) }
                let from = root.pathComponents, to = target.pathComponents
                var common = 0
                while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
                let path = (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(separator: "/")
                return M3UEntry(path: path, title: song.title, start: track.cue?.startSeconds, end: track.cue?.endSeconds)
            }
            let data = try M3UPlaylist(entries: entries).encoded(legacyExtension: legacy)
            var result: Result<URL, Error>?, error: NSError?
            job.coordinator.coordinate(writingItemAt: access.url, options: [], error: &error) { directory in
                result = Result {
                    try Task.checkCancellation()
                    guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileWriteInvalidFileName) }
                    let unsafe = CharacterSet(charactersIn: "/\\:\0\r\n")
                    let safe = String(name.components(separatedBy: unsafe).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(100))
                    let base = safe.isEmpty ? "Playlist" : safe, ext = legacy ? "m3u" : "m3u8"
                    var destination = directory.appendingPathComponent(base).appendingPathExtension(ext), suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path), suffix <= 1000 {
                        destination = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext); suffix += 1
                    }
                    let temporary = directory.appendingPathComponent(".sonora-playlist-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary, options: .withoutOverwriting)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    return destination
                }
            }
            if let error { throw error }
            guard let result else { throw CancellationError() }
            return try result.get()
        }
    }

    private final class Job: @unchecked Sendable { let coordinator = NSFileCoordinator() }
    private static func perform<T: Sendable>(_ body: @escaping @Sendable (Job) throws -> T) async throws -> T {
        let job = Job(), worker = Task.detached(priority: .userInitiated) { try body(job) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}
