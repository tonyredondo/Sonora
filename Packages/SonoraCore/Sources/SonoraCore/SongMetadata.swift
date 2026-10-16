import Foundation

public enum MetadataField: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, artist, album, albumArtist, composer, genre, date
    case trackNumber, trackTotal, discNumber, discTotal, comment, lyrics
    public var id: Self { self }
    public var title: String {
        switch self {
        case .title: "Título"; case .artist: "Artista"; case .album: "Álbum"
        case .albumArtist: "Artista del álbum"; case .composer: "Compositor"; case .genre: "Género"
        case .date: "Fecha / año"; case .trackNumber: "Pista"; case .trackTotal: "Total de pistas"
        case .discNumber: "Disco"; case .discTotal: "Total de discos"; case .comment: "Comentarios"; case .lyrics: "Letra"
        }
    }
    public var isNumber: Bool { [.trackNumber, .trackTotal, .discNumber, .discTotal].contains(self) }
}

public enum ArtworkEdit: Equatable, Sendable { case keep, replace(Data), remove }

public struct MetadataPatch: Sendable {
    public var values: [MetadataField: String]
    public var artwork: ArtworkEdit
    public init(values: [MetadataField: String] = [:], artwork: ArtworkEdit = .keep) {
        self.values = values; self.artwork = artwork
    }
    public func validate() throws {
        for (field, text) in values {
            guard !text.contains("\0"), text.utf8.count <= (field == .lyrics ? 1_000_000 : 16_384) else { throw MetadataValidation.invalid(field) }
            if field.isNumber && !text.isEmpty {
                guard let number = Int(text), (1...65535).contains(number) else { throw MetadataValidation.invalid(field) }
            }
        }
        if case .replace(let data) = artwork, data.isEmpty || data.count > 10_000_000 { throw MetadataValidation.artwork }
    }
}

public enum MetadataValidation: LocalizedError {
    case invalid(MetadataField), artwork
    public var errorDescription: String? {
        switch self {
        case .invalid(let field): "Revisa el campo \(field.title). Los números deben estar entre 1 y 65535."
        case .artwork: "La carátula debe ser una imagen de menos de 10 MB."
        }
    }
}
