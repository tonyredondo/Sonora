import Foundation

public enum LyricsTranslationError: LocalizedError {
    case service(String, String?)
    public var errorDescription: String? {
        guard case let .service(code, reference) = self else { return nil }
        let message: String
        switch code {
        case "codex_disabled": message = "Activa Codex en la configuración del servidor de Sonora."
        case "codex_busy": message = "El servidor está procesando otras letras. Inténtalo de nuevo en un momento."
        case "codex_limit": message = "Se ha alcanzado el límite de uso de Codex. Espera antes de volver a intentarlo."
        case "codex_timeout": message = "Codex ha tardado demasiado en traducir. Puedes volver a intentarlo."
        case "codex_unavailable": message = "No se pudo usar Codex. Comprueba su instalación y la sesión de ChatGPT en el Mac del servidor."
        case "codex_cache_unavailable": message = "El servidor no pudo guardar la traducción."
        case "codex_invalid_response": message = "Codex no devolvió todas las frases correctamente. Puedes volver a intentarlo."
        default: message = "No se pudo traducir la letra. Comprueba que el servidor esté actualizado."
        }
        return message + (reference.map { "\nReferencia: \($0)" } ?? "")
    }
}

/// Sends the complete document for context, but accepts only one result per source
/// ID. Timing stays on the device. The owning store handles the offline cache.
public actor LyricsTranslationClient {
    public static let version = "codex-translation-v1"
    public static let model = "gpt-6.1-sol"
    public static let effort = "medium"
    private let connection: MetadataProxyConnection
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection,
                transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)) {
        self.connection = connection; self.transport = transport
    }
    private struct Line: Codable { let id: Int; let text: String }
    private struct Input: Encodable {
        let lines: [Line]
        let source_language: String
        let target_language: String
        var refresh: Bool?
    }
    private struct Output: Decodable { let lines: [Line]; let model: String; let effort: String }

    public func translate(_ document: LyricsDocument, source: String, target: String, refresh: Bool = false) async throws -> LyricTranslation {
        let lines = document.lines.filter { !$0.text.isEmpty }.map { Line(id: $0.id, text: $0.text) }
        guard !lines.isEmpty, lines.count <= 2000,
              lines.reduce(0, { $0 + $1.text.utf8.count }) <= 100_000,
              lines.allSatisfy({ $0.id >= 0 && $0.id <= UInt32.max && Self.validText($0.text) }),
              source == "auto" || Self.validLanguage(source), Self.validLanguage(target) else {
            throw MusicTextError.invalid("Esta letra o sus idiomas no son válidos para traducir (máximo 2000 frases o 100 KB).")
        }
        try Task.checkCancellation()
        var request = try connection.request(path: "v1/lyrics/translate")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Input(lines: lines, source_language: source, target_language: target,
                                                          refresh: refresh ? true : nil))
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: response.data)
            throw LyricsTranslationError.service(failure?.error ?? "unavailable", MetadataServiceFailure.reference(response.requestID))
        }
        guard response.data.count <= 524_288 else { throw MetadataLookupError.tooLarge }
        guard let output = try? JSONDecoder().decode(Output.self, from: response.data),
              output.model == Self.model, output.effort == Self.effort,
              output.lines.count == lines.count,
              output.lines.reduce(0, { $0 + $1.text.utf8.count }) <= 200_000,
              zip(output.lines, lines).allSatisfy({ $0.id == $1.id && Self.validText($0.text) }) else {
            throw MetadataLookupError.invalidResponse
        }
        return try LyricTranslation(lines: Dictionary(uniqueKeysWithValues: output.lines.map {
            ($0.id, $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }), document: document)
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 10_000
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }
    }
    private static func validLanguage(_ language: String) -> Bool {
        let parts = language.split(separator: "-", omittingEmptySubsequences: false)
        guard let base = parts.first, (2...3).contains(base.utf8.count), language.utf8.count <= 35,
              base.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.utf8.count) && part.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            }
        }
    }
}
