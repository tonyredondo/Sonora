import Foundation

/// An immutable, user-confirmed snapshot. Different editions and devices never overwrite one another.
public struct ConfirmedMetadataRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let audioID: String
    public let confirmedAt: UInt64
    public let values: [String: String]
    public let artwork: Data?
    enum CodingKeys: String, CodingKey { case id, audioID = "audio_id", confirmedAt = "confirmed_at", values, artwork }

    public init(audioID: String, values: [MetadataField: String], artwork: Data?, now: Date = .now) throws {
        id = UUID(); self.audioID = audioID
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 <= 4_102_444_800 else { throw MetadataArchiveError.invalidRecord }
        confirmedAt = UInt64(now.timeIntervalSince1970 * 1000)
        self.values = Dictionary(uniqueKeysWithValues: MetadataField.allCases.map { ($0.rawValue, values[$0] ?? "") })
        self.artwork = artwork
        try validate()
    }
    public var metadata: [MetadataField: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in MetadataField(rawValue: key).map { ($0,value) } })
    }
    public var date: Date { Date(timeIntervalSince1970: Double(confirmedAt) / 1000) }
    public func validate() throws {
        guard Self.validAudioID(audioID), confirmedAt <= 4_102_444_800_000,
              values.keys.allSatisfy({ MetadataField(rawValue: $0) != nil }) else { throw MetadataArchiveError.invalidRecord }
        try MetadataPatch(values: metadata, artwork: artwork.map(ArtworkEdit.replace) ?? .keep).validate()
    }
    public static func validAudioID(_ value: String) -> Bool {
        let prefix = "pcm64-v1:"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count).utf8
        return digest.count == 64 && digest.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public var summary: MetadataRecordSummary {
        MetadataRecordSummary(id:id, title:String((values["title"] ?? "").prefix(200)), artist:String((values["artist"] ?? "").prefix(200)),
            album:String((values["album"] ?? "").prefix(200)), albumArtist:String((values["albumArtist"] ?? "").prefix(200)),
            confirmedAt:confirmedAt, hasArtwork:artwork != nil, hasLyrics:!(values["lyrics"] ?? "").isEmpty)
    }
}

public struct MetadataRecordSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String
    public let confirmedAt: UInt64
    public let hasArtwork: Bool
    public let hasLyrics: Bool
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumArtist = "album_artist", confirmedAt = "confirmed_at", hasArtwork = "has_artwork", hasLyrics = "has_lyrics"
    }
    public var date: Date { Date(timeIntervalSince1970: Double(confirmedAt) / 1000) }
}
public struct MetadataRecordPage: Decodable, Sendable {
    public let records: [MetadataRecordSummary]
    public let nextCursor: Int64?
    enum CodingKeys: String, CodingKey { case records, nextCursor = "next_cursor" }
}
public enum MetadataArchiveError: Error, LocalizedError, Equatable {
    case invalidRecord, conflict, storageFull, unsupported, notCached
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "La copia guardada no coincide con este audio o contiene información no válida."
        case .conflict: "Existe una copia con el mismo identificador y otro contenido. Se ha conservado la copia pendiente."
        case .storageFull: "El almacén del servidor está lleno. Las copias pendientes siguen en este iPhone."
        case .unsupported: "Actualiza el servidor para guardar y recuperar tus ediciones. Las copias pendientes siguen en este iPhone."
        case .notCached: "Esta copia aún no está guardada en este iPhone. Conéctate al servidor para recuperarla."
        }
    }
}
