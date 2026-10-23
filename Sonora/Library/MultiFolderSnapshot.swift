import Foundation
import SonoraCore

struct MultiFolderSnapshot: Codable, Sendable {
    let bookmarks: [String: Data]
    let tracks: [AudioTrack]
    let selectedID: String?
    let position: Double
    let name: String
    let primaryLibraryID: String?

    func resolve() async throws -> (tracks: [AudioTrack], folders: [String: ScopedFolder]) {
        let worker = Task.detached(priority: .userInitiated) {
            var folders: [String: ScopedFolder] = [:]
            for (id, data) in bookmarks {
                try Task.checkCancellation()
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
                   let grant = try? ScopedFolder(url) {
                    // Determine the bookmarked resource while holding its grant;
                    // a file bookmark must never turn into parent-folder access.
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders[id] = grant }
                    else if let access = try? withExtendedLifetime(grant, { try ScopedFolder(document: url) }) { folders[id] = access }
                }
            }
            let available = tracks.compactMap { saved -> AudioTrack? in
                guard let track = AudioTrack(relativePath: saved.relativePath, sourceID: saved.sourceID, cue: saved.cue),
                      let folder = folders[track.sourceID ?? ""] else { return nil }
                let file = track.url(in: folder.url)
                guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      info.isRegularFile == true, info.isSymbolicLink != true,
                      folder.permits(file) else { return nil }
                return track
            }
            guard !available.isEmpty else { throw CocoaError(.fileReadNoPermission) }
            var seen: Set<String> = []
            return (available.filter { seen.insert($0.id).inserted }, folders)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
