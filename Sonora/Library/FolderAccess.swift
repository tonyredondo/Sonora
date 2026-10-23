import Foundation

/// Retained by scans and by every decoder that can still read from the folder.
final class ScopedFolder: @unchecked Sendable {
    let url: URL
    let documentURL: URL?
    private let scopedURL: URL
    private let started: Bool
    init(_ url: URL) throws {
        self.url = url
        documentURL = nil
        scopedURL = url
        started = url.startAccessingSecurityScopedResource()
        if !started && !FileManager.default.isReadableFile(atPath: url.path) {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    /// A document grant covers this file, not its parent folder. Keep the root
    /// used by AudioTrack separate from the URL whose access must stay alive.
    init(document url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.url = url.deletingLastPathComponent()
        documentURL = url
        scopedURL = url
        started = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            if !started && !FileManager.default.isReadableFile(atPath: url.path) { throw CocoaError(.fileReadNoPermission) }
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    deinit { if started { scopedURL.stopAccessingSecurityScopedResource() } }
    func bookmark() throws -> Data {
        try scopedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func permits(_ file: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        if let documentURL { return path == documentURL.resolvingSymlinksInPath().standardizedFileURL.path }
        return path.hasPrefix(url.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }
}

struct FolderSnapshot: Codable {
    let bookmark: Data
    let paths: [String]
    let selectedPath: String?
    let position: Double
    var name: String? = nil
}
