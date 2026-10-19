import CryptoKit
import Foundation

public struct LyricsInterpretation: Codable, Sendable, Equatable {
    public let explanation: String
    public let model: String
    public let effort: String
    public var isValid: Bool {
        model == "gpt-6-astra" && effort == "xhigh"
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && explanation.utf8.count <= 32768
    }
}

public enum LyricsInterpretationError: LocalizedError {
    case service(String, String?)
    public var errorDescription: String? {
        guard case let .service(code, reference) = self else { return nil }
        let message: String
        switch code {
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

/// Only an explicit request sends lyrics. Exact text, language and prompt version
/// identify reusable results; credentials never participate in the cache key.
public actor LyricsInterpretationClient {
    private let connection: MetadataProxyConnection
    private let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache,
                transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)) {
        self.connection = connection; self.cache = cache; self.transport = transport
    }
    public func interpret(lyrics: String, language: String, offline: Bool) async throws -> LyricsInterpretation {
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lyrics.utf8.count <= 65536,
              ["es", "en", "fr", "de", "it", "pt"].contains(language) else { throw MetadataLookupError.invalidSearch }
        struct Input: Encodable { let lyrics: String; let language: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Input(lyrics: lyrics, language: language))
        var request = try connection.request(path: "v1/lyrics/interpret")
        let key = "codex-meaning-v1:gpt-6-astra:xhigh:\(connection.endpoint.absoluteString):" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        if let old = try await cache.read(key: key), old.status == 200,
           let value = try? JSONDecoder().decode(LyricsInterpretation.self, from: old.data), value.isValid {
            try Task.checkCancellation(); return value
        }
        guard !offline else { throw MetadataLookupError.notCached }
        request.httpMethod = "POST"; request.httpBody = body
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
        guard value.isValid else { throw MetadataLookupError.invalidResponse }
        try await cache.store(response.data, key: key, status: 200)
        try Task.checkCancellation()
        return value
    }
}
