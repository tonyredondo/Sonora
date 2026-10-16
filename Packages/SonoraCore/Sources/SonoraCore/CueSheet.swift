import Foundation

/// CUE addresses are CD frames (75 per second), independent of the audio sample rate.
public struct CueSegment: Codable, Equatable, Sendable {
    public let sheetPath: String
    public let number: Int
    public let startCDFrame: Int
    public let endCDFrame: Int?
    public let tags: [MetadataField: String]
    public var startSeconds: Double { Double(startCDFrame) / 75 }
    public var endSeconds: Double? { endCDFrame.map { Double($0) / 75 } }
    public var isValid: Bool {
        AudioTrack(relativePath: sheetPath) != nil && number > 0 && number <= 999 &&
        startCDFrame >= 0 && startCDFrame < 450_000_000 &&
        (endCDFrame.map { $0 > startCDFrame && $0 < 450_000_000 } ?? true)
    }
}

public enum MusicTextError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): reason }
    }
}

/// Shared bounded text decoding for CUE and traditional Windows M3U files.
public enum MusicText {
    public static let maximumBytes = 2 * 1024 * 1024
    /// Read through a caller-owned coordinator so cancellation can stop provider I/O.
    public static func read(_ url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) throws -> Data {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        var result: Result<Data, Error>?, error: NSError?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { local in
            result = Result {
                let file = try FileHandle(forReadingFrom: local)
                defer { try? file.close() }
                var data = Data()
                while data.count <= maximumBytes {
                    guard let chunk = try file.read(upToCount: min(65536, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                guard data.count <= maximumBytes else { throw MusicTextError.invalid("La lista supera el límite de 2 MB.") }
                return data
            }
        }
        if let error { throw error }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
    public static func decode(_ data: Data, utf8Only: Bool = false) throws -> String {
        guard data.count <= maximumBytes else { throw MusicTextError.invalid("La lista supera el límite de 2 MB.") }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = utf8Only ? nil : String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) ?? (utf8Only ? nil : String(data: data, encoding: .windowsCP1252)) }
        guard let text, !text.contains("\0") else { throw MusicTextError.invalid("No se pudo leer la codificación de la lista.") }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }
}

public enum CueSheet {
    private struct Entry {
        let path: String
        let number: Int
        var start: Int?
        var tags: [MetadataField: String] = [:]
    }

    public static func tracks(data: Data, sheetPath: String, availablePaths: Set<String>) throws -> [AudioTrack] {
        let text = try MusicText.decode(data)
        var album: [MetadataField: String] = [:], file: String?, entries: [Entry] = []
        func invalid(_ reason: String) -> MusicTextError { .invalid("\(sheetPath): \(reason)") }
        for raw in text.components(separatedBy: .newlines) {
            let words = try tokens(raw)
            guard let first = words.first else { continue }
            let command = first.uppercased(), values = Array(words.dropFirst())
            switch command {
            case "FILE":
                guard values.count == 2, let base = AudioTrack(relativePath: sheetPath) else { throw invalid("FILE no válido.") }
                let filename = values[0].replacingOccurrences(of: "\\", with: "/")
                guard !filename.hasPrefix("/") else { throw invalid("La ruta CUE debe ser relativa a su carpeta.") }
                var parts = base.folder.split(separator: "/").map(String.init)
                for part in filename.split(separator: "/", omittingEmptySubsequences: false) {
                    if part == "." { continue }
                    if part == ".." {
                        guard !parts.isEmpty else { throw invalid("La ruta CUE queda fuera de la carpeta autorizada.") }
                        parts.removeLast()
                    } else { parts.append(String(part)) }
                }
                let path = parts.joined(separator: "/")
                guard AudioTrack(relativePath: path) != nil, availablePaths.contains(path) else { throw invalid("No se encuentra un archivo de audio autorizado: \(filename).") }
                file = path
            case "TRACK":
                guard values.count == 2, values[1].uppercased() == "AUDIO", let path = file,
                      let number = Int(values[0]), number > 0, number <= 999,
                      number > (entries.last?.number ?? 0), entries.count < 999 else { throw invalid("TRACK no válido o no es de audio.") }
                entries.append(Entry(path: path, number: number))
            case "INDEX":
                guard values.count == 2, !entries.isEmpty, let index = Int(values[0]), (0...99).contains(index) else { throw invalid("INDEX no válido.") }
                let frame = try cdFrame(values[1])
                if index == 1 {
                    guard entries[entries.count - 1].start == nil else { throw invalid("INDEX 01 repetido.") }
                    entries[entries.count - 1].start = frame
                }
            case "TITLE", "PERFORMER", "SONGWRITER":
                guard !values.isEmpty else { throw invalid("Falta el texto de \(command).") }
                let field: MetadataField = command == "TITLE" ? (entries.isEmpty ? .album : .title) : command == "PERFORMER" ? (entries.isEmpty ? .albumArtist : .artist) : .composer
                if entries.isEmpty { album[field] = values.joined(separator: " ") }
                else { entries[entries.count - 1].tags[field] = values.joined(separator: " ") }
            case "REM":
                if values.count >= 2 {
                    let field: MetadataField? = ["DATE": .date, "GENRE": .genre, "DISCNUMBER": .discNumber][values[0].uppercased()]
                    if let field { album[field] = values.dropFirst().joined(separator: " ") }
                }
            case "PREGAP", "POSTGAP":
                guard values.count == 1, try cdFrame(values[0]) == 0 else { throw invalid("Los silencios sintéticos PREGAP/POSTGAP no están admitidos; usa índices almacenados en el audio.") }
            default: break // CATALOG, ISRC, FLAGS and CD-TEXT do not change sample boundaries.
            }
        }
        guard !entries.isEmpty else { throw invalid("No contiene pistas de audio.") }
        var lastStarts: [String: Int] = [:], closed: Set<String> = [], previous: String?
        return try entries.enumerated().map { index, entry in
            guard let start = entry.start else { throw invalid("Falta INDEX 01 en la pista \(entry.number).") }
            if let previous, previous != entry.path { closed.insert(previous) }
            guard !closed.contains(entry.path), lastStarts[entry.path].map({ start > $0 }) ?? true else { throw invalid("Los índices no están en orden.") }
            lastStarts[entry.path] = start; previous = entry.path
            let next = index + 1 < entries.count && entries[index + 1].path == entry.path ? entries[index + 1].start : nil
            var tags = album.merging(entry.tags) { _, track in track }
            tags[.artist] = tags[.artist] ?? tags[.albumArtist]
            tags[.title] = tags[.title] ?? "Pista \(entry.number)"
            tags[.trackNumber] = String(entry.number)
            let segment = CueSegment(sheetPath: sheetPath, number: entry.number, startCDFrame: start, endCDFrame: next, tags: tags)
            guard let track = AudioTrack(relativePath: entry.path, cue: segment) else { throw invalid("Límites de pista no válidos.") }
            return track
        }
    }

    private static func cdFrame(_ value: String) throws -> Int {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frame = Int(parts[2]),
              (0..<100_000).contains(minutes), (0..<60).contains(seconds), (0..<75).contains(frame) else { throw MusicTextError.invalid("Tiempo CUE no válido: \(value).") }
        return (minutes * 60 + seconds) * 75 + frame
    }
    private static func tokens(_ line: String) throws -> [String] {
        var values: [String] = [], token = "", quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted { if !token.isEmpty { values.append(token); token = "" } }
            else { token.append(character) }
        }
        guard !quoted else { throw MusicTextError.invalid("Comillas sin cerrar en CUE.") }
        if !token.isEmpty { values.append(token) }
        return values
    }
}
