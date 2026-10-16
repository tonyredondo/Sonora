import Foundation

public struct MetadataProxyEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let data: Value
    public let sources: [String]
}

public struct MetadataRecording: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let durationMS: Int?
    public let disambiguation: String?
    public let score: Int?
    public let releases: [MetadataReleaseChoice]
    public let genres: [String]
    enum CodingKeys: String, CodingKey {
        case id, title, artist, disambiguation, score, releases, genres
        case durationMS = "duration_ms"
    }
}

public struct MetadataReleaseChoice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let date: String?
    public let country: String?
    public let disambiguation: String?
}

public struct MetadataArtistCredit: Codable, Sendable {
    public let name: String?
    public let artist: Artist?
    public let joinphrase: String?
    public struct Artist: Codable, Sendable { public let name: String? }
    public static func joined(_ credits: [Self]?) -> String {
        (credits ?? []).map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
    }
}

public struct MetadataRelease: Codable, Sendable {
    public let id: String
    public let title: String
    public let date: String?
    public let artistCredit: [MetadataArtistCredit]?
    public let media: [Medium]
    enum CodingKeys: String, CodingKey { case id, title, date, media; case artistCredit = "artist-credit" }
    public struct Medium: Codable, Sendable {
        public let position: Int
        public let trackCount: Int?
        public let tracks: [Track]?
        enum CodingKeys: String, CodingKey { case position, tracks; case trackCount = "track-count" }
    }
    public struct Track: Codable, Sendable {
        public let position: Int
        public let title: String?
        public let recording: RecordingReference
        public struct RecordingReference: Codable, Sendable { public let id: String }
    }
    /// Track/disc positions are suggested only for an unambiguous recording occurrence.
    public func suggestedValues(for recording: MetadataRecording) -> [MetadataField: String] {
        var result: [MetadataField: String] = [.title: recording.title, .artist: recording.artist, .album: title]
        let albumArtist = MetadataArtistCredit.joined(artistCredit)
        if !albumArtist.isEmpty { result[.albumArtist] = albumArtist }
        if let date, !date.isEmpty { result[.date] = date }
        if !recording.genres.isEmpty { result[.genre] = recording.genres.joined(separator: "; ") }
        let matches = media.flatMap { medium in (medium.tracks ?? []).filter { $0.recording.id == recording.id }.map { (medium, $0) } }
        if matches.count == 1, let (medium, track) = matches.first {
            if let title = track.title, !title.isEmpty { result[.title] = title }
            if (1...65535).contains(track.position) { result[.trackNumber] = String(track.position) }
            if let count = medium.trackCount, (1...65535).contains(count) { result[.trackTotal] = String(count) }
            if (1...65535).contains(medium.position) { result[.discNumber] = String(medium.position) }
            if !media.isEmpty { result[.discTotal] = String(media.count) }
        }
        return result
    }
}

public struct MetadataLyrics: Codable, Sendable {
    public let id: Int
    public let trackName: String
    public let artistName: String
    public let albumName: String
    public let duration: Double
    public let instrumental: Bool
    public let plainLyrics: String?
    public let syncedLyrics: String?
}

public struct MetadataIdentification: Codable, Sendable {
    public let status: String
    public let results: [Match]
    public struct Match: Codable, Sendable {
        public let score: Double
        public let recordings: [Recording]?
        public struct Recording: Codable, Sendable { public let id: String }
    }
    /// A fingerprint can point to several recordings; the user must choose one.
    public var recordingIDs: [String] {
        var seen: Set<String> = []
        return Array(results.sorted { $0.score > $1.score }.flatMap { $0.recordings ?? [] }
            .map(\.id).filter { UUID(uuidString: $0) != nil && seen.insert($0).inserted }.prefix(10))
    }
}

public struct MetadataSearch: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public init(title: String, artist: String = "", album: String = "") { self.title = title; self.artist = artist; self.album = album }
}

public enum MetadataSuggestions {
    public static func changes(proposed: [MetadataField: String], current: [MetadataField: String], onlyMissing: Bool) -> [MetadataField: String] {
        proposed.filter { field, value in
            !value.isEmpty && value != current[field] && (!onlyMissing || (current[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

public enum MetadataLookupError: LocalizedError, Equatable {
    case invalidConnection, invalidSearch, notCached, unauthorized, notFound, invalidResponse, unavailable, cacheUnavailable, tooLarge, recognitionUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidConnection: "Usa una dirección HTTPS o HTTP de tu red local, sin usuario, contraseña ni parámetros. 0.0.0.0 es una dirección de escucha, no la del servidor."
        case .invalidSearch: "Escribe un título para buscar. Los campos deben tener menos de 1024 caracteres."
        case .notCached: "No hay una copia guardada para esta consulta. Conéctate para buscar."
        case .unauthorized: "El servidor ha rechazado la conexión. Revisa su token de acceso."
        case .notFound: "No se ha encontrado información para esta consulta."
        case .invalidResponse: "El servidor ha devuelto una respuesta que Sonora no puede leer."
        case .unavailable: "No se pudo completar la consulta al servidor. Puedes seguir escuchando y editar la información local."
        case .cacheUnavailable: "No se pudo leer o guardar la copia para usarla sin conexión."
        case .tooLarge: "La respuesta supera el límite de tamaño."
        case .recognitionUnavailable: "El reconocimiento de audio necesita una clave de aplicación de AcoustID configurada en tu servidor. Puedes buscar por título y artista."
        }
    }
}
