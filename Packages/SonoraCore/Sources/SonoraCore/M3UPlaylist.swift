import Foundation

public struct M3UEntry: Equatable, Sendable {
    public let path: String
    public let title: String?
    public let start: Double?
    public let end: Double?
    public init(path: String, title: String? = nil, start: Double? = nil, end: Double? = nil) {
        self.path = path; self.title = title; self.start = start; self.end = end
    }
}
public struct PlaylistProblem: Identifiable, Equatable, Sendable {
    public let id = UUID().uuidString
    public let line: Int
    public let path: String
    public let reason: String
    public init(line: Int, path: String, reason: String) { self.line = line; self.path = path; self.reason = reason }
}

public struct M3UPlaylist: Sendable {
    public let entries: [M3UEntry]
    public let problems: [PlaylistProblem]
    public init(entries: [M3UEntry], problems: [PlaylistProblem] = []) { self.entries = entries; self.problems = problems }

    public static func decode(_ data: Data, utf8Only: Bool = false) throws -> M3UPlaylist {
        let text = try MusicText.decode(data, utf8Only: utf8Only)
        var entries: [M3UEntry] = [], problems: [PlaylistProblem] = []
        var title: String?, start: Double?, end: Double?
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-") { throw MusicTextError.invalid("Esta lista es una emisión HLS. Elige una M3U de archivos locales.") }
            if line.hasPrefix("#EXTINF:"), let comma = line.firstIndex(of: ",") { title = String(line[line.index(after: comma)...]); continue }
            if line.hasPrefix("#EXTVLCOPT:start-time=") || line.hasPrefix("#EXTVLCOPT:stop-time=") {
                guard let equal = line.firstIndex(of: "="), let seconds = Double(line[line.index(after: equal)...]), seconds.isFinite, (0..<6_000_000).contains(seconds) else {
                    throw MusicTextError.invalid("Límite de tiempo no válido en la línea \(index + 1).")
                }
                if line.hasPrefix("#EXTVLCOPT:start") { start = seconds } else { end = seconds }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard entries.count + problems.count < 10_000 else { throw MusicTextError.invalid("La lista supera las 10.000 entradas.") }
            defer { title = nil; start = nil; end = nil }
            guard end.map({ $0 > (start ?? 0) }) ?? true else { throw MusicTextError.invalid("El final precede al inicio en la línea \(index + 1).") }
            var path = line
            if path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
            if path.lowercased().hasPrefix("file:") {
                guard let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                    problems.append(.init(line: index + 1, path: path, reason: "La dirección no es un archivo local.")); continue
                }
                path = url.path
            } else if path.contains("://") {
                problems.append(.init(line: index + 1, path: path, reason: "Las emisiones por Internet no están admitidas.")); continue
            }
            entries.append(M3UEntry(path: path, title: title, start: start, end: end))
        }
        guard !entries.isEmpty || !problems.isEmpty else { throw MusicTextError.invalid("La lista no contiene archivos.") }
        return M3UPlaylist(entries: entries, problems: problems)
    }

    /// Both extensions use UTF-8; the M3U variant declares its encoding explicitly.
    public func encoded(legacyExtension: Bool = false) throws -> Data {
        var lines = ["#EXTM3U"]
        if legacyExtension { lines.append("#EXTENC:UTF-8") }
        for entry in entries {
            guard !entry.path.isEmpty, !entry.path.contains(where: { $0.isNewline || $0 == "\0" }),
                  entry.start.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  entry.end.map({ $0.isFinite && $0 > (entry.start ?? 0) }) ?? true else { throw MusicTextError.invalid("La ruta o los límites de una canción no se pueden exportar.") }
            if let title = entry.title { lines.append("#EXTINF:-1," + title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")) }
            if let start = entry.start { lines.append("#EXTVLCOPT:start-time=" + String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), start)) }
            if let end = entry.end { lines.append("#EXTVLCOPT:stop-time=" + String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), end)) }
            lines.append(entry.path.hasPrefix("#") ? "./" + entry.path : entry.path)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= MusicText.maximumBytes else { throw MusicTextError.invalid("La lista supera el límite de 2 MB.") }
        return data
    }

    /// A list may use ../, but every resolved target must stay in the selected root.
    public static func relativePath(_ path: String, playlist: URL, root: URL) throws -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : playlist.deletingLastPathComponent().appendingPathComponent(path)
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let absolute = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard absolute.hasPrefix(prefix), let track = AudioTrack(relativePath: String(absolute.dropFirst(prefix.count))) else {
            throw MusicTextError.invalid("La ruta queda fuera de la carpeta autorizada.")
        }
        return track.relativePath
    }
}
