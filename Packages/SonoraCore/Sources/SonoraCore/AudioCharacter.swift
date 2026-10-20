import Foundation

/// Independent model affinities, never percentages of accuracy. Labels retain
/// their Discogs taxonomy identity; presentation may localize a known style.
public struct AudioCharacter: Codable, Equatable, Sendable {
    public static let version = "essentia-discogs-v1"
    public struct Style: Codable, Equatable, Sendable {
        public let label: String
        public let score: Double
    }
    public let version: String
    public let silent: Bool
    public let styles: [Style]
    public let moods: [String: Double]
    public var isValid: Bool {
        version == Self.version && styles.count <= 8 && silent == styles.isEmpty
            && Set(styles.map(\.label)).count == styles.count
            && styles.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.label.utf8.count <= 200 && !$0.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && $0.score.isFinite && (0...1).contains($0.score) }
            && Set(moods.keys) == ["happy", "sad", "relaxed", "aggressive"]
            && moods.values.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    public var prominentMoods: [String] {
        // Keep a stable reading order; these classifiers are independent.
        let order = ["happy", "sad", "relaxed", "aggressive"]
        let strongest = Set(order.filter { (moods[$0] ?? 0) >= 0.6 }
            .sorted { (moods[$0] ?? 0) > (moods[$1] ?? 0) }.prefix(2))
        return order.filter { strongest.contains($0) }
    }
}

public enum AudioCharacterError: LocalizedError {
    case service(String)
    public var errorDescription: String? {
        guard case .service(let code) = self else { return nil }
        switch code {
        case "offline": return "Conecta con tu servidor y desactiva el modo sin conexión para actualizar el estilo y ambiente."
        case "audio_character_disabled", "audio_character_unavailable":
            return "Activa el análisis de estilo y ambiente e instala sus modelos en el servidor de Sonora."
        case "audio_character_busy": return "El servidor está analizando otras canciones. Inténtalo en un momento."
        case "audio_character_timeout": return "El análisis ha tardado demasiado. Puedes volver a intentarlo."
        default: return "No se pudo analizar el estilo y ambiente. Comprueba la conexión y que el servidor esté actualizado."
        }
    }
}

/// The owning store checks its content-addressed local cache before preparing
/// any PCM. Only sampled audio is sent to the user's configured Sonora server.
public struct AudioCharacterClient: Sendable {
    private let connection: MetadataProxyConnection
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 100, resourceTimeout: 110)) {
        self.connection = connection; self.transport = transport
    }
    public func checkAvailability() async throws {
        let response = try await transport.send(connection.request(path: "v1/status"))
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        struct Status: Decodable {
            struct Capability: Decodable { let enabled: Bool; let version: String }
            let audio_character: Capability?
        }
        guard response.status == 200, response.data.count <= 65_536,
              let status = try? JSONDecoder().decode(Status.self, from: response.data),
              status.audio_character?.enabled == true, status.audio_character?.version == AudioCharacter.version else {
            throw AudioCharacterError.service("audio_character_disabled")
        }
    }
    public func analyze(_ audio: Data, refresh: Bool = false) async throws -> AudioCharacter {
        guard (32_044...2_880_044).contains(audio.count) else { throw MetadataLookupError.invalidSearch }
        var request = try connection.request(path: "v1/audio/character", parameters: refresh ? [.init(name: "refresh", value: "true")] : [])
        request.httpMethod = "POST"; request.httpBody = audio
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            throw AudioCharacterError.service((try? JSONDecoder().decode(Failure.self, from: response.data))?.error ?? "unavailable")
        }
        guard response.data.count <= 32_768, let result = try? JSONDecoder().decode(AudioCharacter.self, from: response.data), result.isValid else {
            throw MetadataLookupError.invalidResponse
        }
        return result
    }
}
