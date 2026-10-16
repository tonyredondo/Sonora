import Foundation

/// Retained by scans and by every decoder that can still read from the folder.
final class ScopedFolder: @unchecked Sendable {
    let url: URL
    private let started: Bool
    init(_ url: URL) throws {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
        if !started && !FileManager.default.isReadableFile(atPath: url.path) {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
    func bookmark() throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

struct FolderSnapshot: Codable {
    let bookmark: Data
    let paths: [String]
    let selectedPath: String?
    let position: Double
    var name: String? = nil
}
