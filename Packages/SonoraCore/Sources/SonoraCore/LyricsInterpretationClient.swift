import CryptoKit
import Foundation

/// Song identity and estimated audio tags, supplied as context rather than facts
/// about the author's intent. Timestamps are deliberately absent.
public struct LyricsInterpretationContext: Codable, Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let styles: [String]
    public let moods: [String]
    public init(title: String = "", artist: String = "", album: String = "", styles: [String] = [], moods: [String] = []) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.styles = styles; self.moods = moods
    }
    public var isValid: Bool {
        [title, artist, album].allSatisfy { $0.utf8.count <= 4096 && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
            && styles.count <= 2 && styles.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= 200 && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
            && moods.count <= 2 && moods.allSatisfy { ["happy", "sad", "relaxed", "aggressive"].contains($0) }
    }
    public var cacheIdentity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // This value contains only strings and arrays of strings.
        let bytes = try! encoder.encode(self)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LyricsInterpretation: Codable, Sendable, Equatable {
    public let explanation: String
    public let model: String
    public let effort: String
    public var isValid: Bool {
        model == "gpt-6-astra" && ["medium", "xhigh"].contains(effort)
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && explanation.utf8.count <= 32768
    }
}

public enum LyricsInterpretationError: LocalizedError {
    case service(String, String?)
    public var errorDescription: String? {
        guard case let .service(code, reference) = self else { return nil }
        let message: String
        switch code {
        case "album_unavailable": message = "Actualiza el servidor de Sonora para preparar el análisis del álbum."
        case "codex_disabled": message = "Activa Codex en la configuración del servidor de Sonora."
        case "codex_busy": message = "El servidor está interpretando otras letras. Inténtalo de nuevo en un momento."
        case "codex_limit": message = "Se ha alcanzado el límite de uso de Codex. Espera antes de volver a intentarlo."
        case "codex_timeout": message = "Codex ha tardado demasiado en responder. Puedes volver a intentarlo."
        case "codex_unavailable": message = "No se pudo usar Codex. Comprueba su instalación y la sesión de ChatGPT en el Mac del servidor."
        case "codex_cache_unavailable": message = "El servidor no pudo guardar la interpretación en caché."
        case "codex_invalid_response": message = "Codex no devolvió una interpretación válida. Puedes volver a intentarlo."
        default: message = "No se pudo interpretar la letra. Comprueba que el servidor esté actualizado."
        }
        return message + (reference.map { "\nReferencia: \($0)" } ?? "")
    }
}

/// Callers choose whether to generate or read offline. Text, song context, language and prompt version
/// identify reusable results; credentials never participate in the cache key.
public actor LyricsInterpretationClient {
    // New generation: regenerate previous readings once when adopting medium.
    public static let version = "codex-meaning-v3"
    public static let effort = "medium"
    private let connection: MetadataProxyConnection
    private let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache,
                transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)) {
        self.connection = connection; self.cache = cache; self.transport = transport
    }
    /// Refresh bypasses both caches, replacing the saved result only after success.
    public func interpret(lyrics: String, language: String, context: LyricsInterpretationContext = .init(), offline: Bool, refresh: Bool = false) async throws -> LyricsInterpretation {
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lyrics.utf8.count <= 65536,
              context.isValid, ["es", "en", "fr", "de", "it", "pt"].contains(language) else { throw MetadataLookupError.invalidSearch }
        struct Input: Encodable { let lyrics: String; let language: String; let context: LyricsInterpretationContext; let effort: String; var refresh: Bool? }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Input(lyrics: lyrics, language: language, context: context, effort: Self.effort))
        var request = try connection.request(path: "v1/lyrics/interpret")
        let key = "\(Self.version):gpt-6-astra:\(Self.effort):\(connection.endpoint.absoluteString):" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        if !refresh, let old = try await cache.read(key: key), old.status == 200,
           let value = try? JSONDecoder().decode(LyricsInterpretation.self, from: old.data), value.isValid, value.effort == Self.effort {
            try Task.checkCancellation(); return value
        }
        guard !offline else { throw MetadataLookupError.notCached }
        request.httpMethod = "POST"
        request.httpBody = refresh ? try encoder.encode(Input(lyrics: lyrics, language: language, context: context, effort: Self.effort, refresh: true)) : body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: response.data)
            throw LyricsInterpretationError.service(failure?.error ?? "unavailable", MetadataServiceFailure.reference(response.requestID))
        }
        guard response.data.count <= 131072 else { throw MetadataLookupError.tooLarge }
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: response.data)
        guard value.isValid, value.effort == Self.effort else { throw MetadataLookupError.invalidResponse }
        try await cache.store(response.data, key: key, status: 200)
        try Task.checkCancellation()
        return value
    }
}
