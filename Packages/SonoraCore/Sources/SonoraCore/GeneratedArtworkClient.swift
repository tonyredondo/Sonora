import CryptoKit
import Foundation

/// Song-specific visual context. Lyrics and local file paths are never uploaded.
public struct GeneratedArtworkInput: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let albumDescription: String
    public let genre: String
    public let styles: [String]
    public let moods: [String]
    enum CodingKeys: String, CodingKey { case title, artist, album, albumDescription = "album_description", genre, styles, moods }
    public init(title: String, artist: String, album: String, albumDescription: String, genre: String = "", styles: [String] = [], moods: [String] = []) {
        self.title = title; self.artist = artist; self.album = album; self.albumDescription = albumDescription
        self.genre = genre; self.styles = styles; self.moods = moods
    }
    public var isValid: Bool {
        func plain(_ value: String, limit: Int) -> Bool { value.utf8.count <= limit && !value.unicodeScalars.contains { $0.properties.generalCategory == .control } }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [title, artist, album, genre].allSatisfy { plain($0, limit: 4096) }
            && albumDescription.utf8.count <= 32768
            && !albumDescription.unicodeScalars.contains { $0.properties.generalCategory == .control && ![9, 10, 13].contains($0.value) }
            && styles.count <= 2 && styles.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && plain($0, limit: 200) }
            && moods.count <= 2 && moods.allSatisfy { ["happy", "sad", "relaxed", "aggressive"].contains($0) }
    }
    public var cacheIdentity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return "codex-artwork-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum GeneratedArtworkIssue: LocalizedError {
    case unavailable, invalidImage
    case service(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "No se pudo generar la portada. Comprueba Codex y la versión del servidor."
        case .invalidImage: "La portada generada no es una imagen válida."
        case .service(let code):
            switch code {
            case "codex_limit": "Se ha alcanzado el límite de uso de Codex. Espera antes de volver a intentarlo."
            case "codex_busy": "Codex está preparando otras canciones. Inténtalo de nuevo en un momento."
            case "codex_timeout": "Codex ha tardado demasiado en generar la portada. Puedes volver a intentarlo."
            case "codex_disabled": "Activa Codex en la configuración del servidor de Sonora."
            case "codex_cache_unavailable": "El servidor no pudo guardar la portada generada."
            default: "No se pudo generar la portada. Comprueba Codex y la versión del servidor."
            }
        }
    }
}

public actor GeneratedArtworkClient {
    private let connection: MetadataProxyConnection
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection,
                transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)) {
        self.connection = connection; self.transport = transport
    }
    public func generate(_ input: GeneratedArtworkInput, offline: Bool) async throws -> Data {
        guard input.isValid else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        var request = try connection.request(path: "v1/artwork/generate")
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(input)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: response.data)
            throw GeneratedArtworkIssue.service(failure?.error ?? "unavailable")
        }
        guard response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "image/png",
              Self.isPNG(response.data) else { throw GeneratedArtworkIssue.invalidImage }
        return response.data
    }
    public static func isPNG(_ data: Data) -> Bool {
        guard (45...10_000_000).contains(data.count), data.starts(with: [137,80,78,71,13,10,26,10]),
              Array(data[12..<16]) == [73,72,68,82], data.suffix(12) == Data([0,0,0,0,73,69,78,68,174,66,96,130]) else { return false }
        func word(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) } }
        let width = word(16), height = word(20)
        return width > 0 && width == height && width <= 2048
    }
}
