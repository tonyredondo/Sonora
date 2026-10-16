import Foundation

public enum FolderScanner {
    public static let defaultExtensions: Set<String> = ["mp3", "wav", "wave", "flac", "aac", "m4a", "aif", "aiff", "caf", "ogg", "opus", "wv", "ape", "mpc", "tta", "spx"]

    public static func scan(_ root: URL, extensions: Set<String> = defaultExtensions,
                            isCancelled: @Sendable () -> Bool = { false },
                            readText: (@Sendable (URL) throws -> Data)? = nil) throws -> [AudioTrack] {
        if isCancelled() { throw CancellationError() }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var tracks: [AudioTrack] = [], sheets: [String] = []
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // DirectoryEnumerator does not traverse symlinks. Calling
            // skipDescendants on a file link can skip its following siblings.
            if values.isSymbolicLink == true { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "cue",
                  path.hasPrefix(prefix),
                  let track = AudioTrack(relativePath: String(path.dropFirst(prefix.count))) else { continue }
            if url.pathExtension.lowercased() == "cue" { sheets.append(track.relativePath) }
            else { tracks.append(track) }
        }
        if let enumerationError { throw enumerationError }
        let available = Set(tracks.map(\.relativePath))
        var represented: Set<String> = [], virtual: [AudioTrack] = []
        for sheet in sheets.sorted() {
            if isCancelled() { throw CancellationError() }
            let url = root.appendingPathComponent(sheet)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= MusicText.maximumBytes else { throw MusicTextError.invalid("El CUE supera el límite de 2 MB.") }
            let data = try readText.map { try $0(url) } ?? MusicText.read(url)
            if isCancelled() { throw CancellationError() }
            let segments = try CueSheet.tracks(data: data, sheetPath: sheet, availablePaths: available)
            let paths = Set(segments.map(\.relativePath))
            guard represented.isDisjoint(with: paths) else { throw MusicTextError.invalid("Varios CUE hacen referencia al mismo archivo de audio.") }
            represented.formUnion(paths); virtual.append(contentsOf: segments)
        }
        return (tracks.filter { !represented.contains($0.relativePath) } + virtual).sorted {
            let a = $0.cue?.sheetPath ?? $0.relativePath, b = $1.cue?.sheetPath ?? $1.relativePath
            if a == b { return ($0.cue?.number ?? 0) < ($1.cue?.number ?? 0) }
            let order = a.compare(b, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }
}
