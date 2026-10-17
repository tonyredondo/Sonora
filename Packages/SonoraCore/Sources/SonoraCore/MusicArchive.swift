import Foundation
import ZIPFoundation

public struct MusicArchiveProgress: Sendable { public let bytes: Int64 }
public struct MusicArchiveResult: Sendable { public let files: Int; public let bytes: Int64 }
public enum MusicArchiveError: LocalizedError {
    case unsafePath, expandedLimit, nestingLimit, corrupt
    public var errorDescription: String? {
        switch self {
        case .unsafePath: "El ZIP contiene rutas, enlaces o nombres de archivo que no se pueden importar."
        case .expandedLimit: "El contenido descomprimido supera el espacio disponible o el límite de archivos."
        case .nestingLimit: "El ZIP contiene demasiados archivos comprimidos unos dentro de otros."
        case .corrupt: "El archivo ZIP está dañado o usa un formato de compresión no compatible."
        }
    }
}

public enum MusicArchive {
    /// Extracts into a new directory. On failure, only that new directory is removed.
    /// Stored filenames are never allowed to escape its root or overwrite a file.
    public static func extract(_ archive: URL, to destination: URL, maxBytes: Int64 = 32 * 1024 * 1024 * 1024,
                               isCancelled: () -> Bool = { false }, progress: (MusicArchiveProgress) -> Void = { _ in }) throws -> MusicArchiveResult {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        guard maxBytes > 0 else { throw MusicArchiveError.expandedLimit }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? files.removeItem(at: destination) } }
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        var expandedBytes: Int64 = 0, entriesProcessed = 0, lastReport = -Double.infinity
        func check() throws { if isCancelled() { throw CancellationError() } }
        func report(force: Bool = false) {
            let now = Date.timeIntervalSinceReferenceDate
            if force || now - lastReport >= 0.1 { progress(.init(bytes: expandedBytes)); lastReport = now }
        }
        func unpack(_ source: URL, into folder: URL, depth: Int) throws {
            try check()
            guard depth <= 4 else { throw MusicArchiveError.nestingLimit }
            let zip: Archive
            do { zip = try Archive(url: source, accessMode: .read) }
            catch { throw MusicArchiveError.corrupt }
            var nested: [URL] = []
            for entry in zip {
                try check(); entriesProcessed += 1
                guard entriesProcessed <= 100_000 else { throw MusicArchiveError.expandedLimit }
                var path = entry.path.replacingOccurrences(of: "\\", with: "/")
                if entry.type == .directory { while path.hasSuffix("/") { path.removeLast() } }
                guard AudioTrack(relativePath: path) != nil, path.utf8.count <= 4096,
                      !path.hasPrefix("/"), !path.hasPrefix("~"),
                      !path.hasPrefix("//"), path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
                      entry.type != .symlink else { throw MusicArchiveError.unsafePath }
                let components = path.split(separator: "/")
                if components.first == "__MACOSX" || components.last?.hasPrefix("._") == true || components.last == ".DS_Store" { continue }
                let target = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard target.path.hasPrefix(root.path + "/") else { throw MusicArchiveError.unsafePath }
                if entry.type == .directory {
                    try files.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                guard entry.uncompressedSize <= UInt64(maxBytes - expandedBytes) else { throw MusicArchiveError.expandedLimit }
                guard !files.fileExists(atPath: target.path) else { throw MusicArchiveError.unsafePath }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard files.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: target)
                do {
                    var written: Int64 = 0
                    let checksum = try zip.extract(entry, bufferSize: 64 * 1024) { data in
                        try check()
                        guard Int64(data.count) <= maxBytes - expandedBytes else { throw MusicArchiveError.expandedLimit }
                        written += Int64(data.count); expandedBytes += Int64(data.count)
                        guard UInt64(written) <= entry.uncompressedSize else { throw MusicArchiveError.corrupt }
                        try output.write(contentsOf: data); report()
                    }
                    try output.close()
                    guard checksum == entry.checksum, UInt64(written) == entry.uncompressedSize else { throw MusicArchiveError.corrupt }
                } catch { try? output.close(); throw error }
                if target.pathExtension.lowercased() == "zip" { nested.append(target) }
            }
            for zip in nested {
                try unpack(zip, into: zip.deletingPathExtension(), depth: depth + 1)
                try files.removeItem(at: zip)
            }
        }
        try unpack(archive, into: root, depth: 0)
        try check(); report(force: true)
        var count = 0, bytes: Int64 = 0
        guard let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in iterator {
            try check()
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if info.isRegularFile == true { count += 1; bytes += Int64(info.fileSize ?? 0) }
        }
        completed = true
        return MusicArchiveResult(files: count, bytes: bytes)
    }
}
