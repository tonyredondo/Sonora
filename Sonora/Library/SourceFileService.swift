import Foundation
import SonoraCore

struct SourceFile: Identifiable, Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let fingerprint: FileFingerprint
    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }
}

/// Uses the source's live security scope for provider coordination. A displayed
/// item is checked again at deletion so a replaced file requires a new review.
enum SourceFileService {
    static func contents(in folder: ScopedFolder, path: String = "") async throws -> [SourceFile] {
        try await Task.detached(priority: .userInitiated) {
            let directory = try checkedURL(path, root: folder.url, allowRoot: true)
            var coordinationError: NSError?, result: Result<[SourceFile], Error>?
            NSFileCoordinator().coordinate(readingItemAt: directory, options: .withoutChanges, error: &coordinationError) { local in
                result = Result {
                    let files = FileManager.default
                    return try files.contentsOfDirectory(at: local, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).compactMap { url in
                        let attributes = try files.attributesOfItem(atPath: url.path)
                        let type = attributes[.type] as? FileAttributeType
                        guard type == .typeDirectory || type == .typeRegular else { return nil }
                        let relative = path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
                        _ = try checkedURL(relative, root: folder.url)
                        return SourceFile(relativePath: relative, isDirectory: type == .typeDirectory, fingerprint: try FileFingerprint(url))
                    }.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
        }.value
    }

    /// Once confirmed, complete the filesystem operation even if the presenting
    /// view disappears. The caller must reconcile its library after completion.
    static func remove(_ item: SourceFile, from folder: ScopedFolder) async throws {
        try await Task.detached(priority: .userInitiated) {
            let url = try checkedURL(item.relativePath, root: folder.url)
            var coordinationError: NSError?, result: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { local in
                result = Result {
                    let checked = try checkedURL(item.relativePath, root: folder.url)
                    guard local.standardizedFileURL.resolvingSymlinksInPath() == checked.standardizedFileURL.resolvingSymlinksInPath(),
                          try FileFingerprint(local) == item.fingerprint else {
                        throw MusicTextError.invalid("El archivo o la carpeta ha cambiado. Actualiza la vista antes de borrarlo.")
                    }
                    let type = try FileManager.default.attributesOfItem(atPath: local.path)[.type] as? FileAttributeType
                    guard type == (item.isDirectory ? .typeDirectory : .typeRegular) else { throw CocoaError(.fileWriteNoPermission) }
                    try FileManager.default.removeItem(at: local)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            try result.get()
        }.value
    }

    private static func checkedURL(_ path: String, root: URL, allowRoot: Bool = false) throws -> URL {
        guard root.isFileURL, (allowRoot && path.isEmpty) || AudioTrack(relativePath: path) != nil else { throw CocoaError(.fileWriteNoPermission) }
        var current = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            let type = try FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else { throw CocoaError(.fileWriteNoPermission) }
        }
        return current
    }
}
