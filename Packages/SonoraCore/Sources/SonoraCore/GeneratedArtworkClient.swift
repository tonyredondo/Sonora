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
    case unavailable, invalidImage, serverUpdateRequired
    case service(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "No se pudo generar la portada. Comprueba Codex y la versión del servidor."
        case .invalidImage: "La portada generada no es una imagen válida."
        case .serverUpdateRequired: "Actualiza el servidor de Sonora para preparar portadas que se puedan recuperar al volver a la app."
        case .service(let code):
            switch code {
            case "codex_limit": "Se ha alcanzado el límite de uso de Codex. Espera antes de volver a intentarlo."
            case "codex_busy": "Codex está preparando otras canciones. Inténtalo de nuevo en un momento."
            case "codex_timeout": "Codex ha tardado demasiado en generar la portada. Puedes volver a intentarlo."
            case "codex_disabled": "Activa Codex en la configuración del servidor de Sonora."
            case "codex_cache_unavailable": "El servidor no pudo guardar la portada generada."
            case "codex_result_expired": "La portada ya no está guardada en el servidor. Puedes solicitarla de nuevo."
            default: "No se pudo generar la portada. Comprueba Codex y la versión del servidor."
            }
        }
    }
}

public struct GeneratedArtworkJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed }
    public let id: String
    public let state: State
    public let error: String?
    public init(id: String, state: State, error: String? = nil) { self.id = id; self.state = state; self.error = error }
    public static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public actor GeneratedArtworkClient {
    public enum Kind: Sendable { case square, headerExtension }
    private let kind: Kind
    private var jobsPath: String { kind == .square ? "v1/artwork/jobs" : "v1/artwork/expansions/jobs" }
    private let connection: MetadataProxyConnection
    private let transport: any MetadataLookupTransport
    private let jobsTransport: any MetadataLookupTransport
    private let imageTransport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection,
                transport: (any MetadataLookupTransport)? = nil, kind: Kind = .square) {
        self.kind = kind
        self.connection = connection
        self.transport = transport ?? MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)
        jobsTransport = transport ?? MetadataURLSessionTransport(requestTimeout: 15, resourceTimeout: 30)
        imageTransport = transport ?? MetadataURLSessionTransport(requestTimeout: 30, resourceTimeout: 180)
    }
    public func submit(_ input: GeneratedArtworkInput, retryFailed: Bool = false, offline: Bool) async throws -> GeneratedArtworkJob {
        guard kind == .square, input.isValid else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        var request = try connection.request(path: jobsPath, parameters: retryFailed ? [URLQueryItem(name: "retry_failed", value: "true")] : [])
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(input)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await jobsTransport.send(request)
        if response.status == 404 || response.status == 405 { throw GeneratedArtworkIssue.serverUpdateRequired }
        try checkJobResponse(response, accepted: [200, 202])
        return try decodeJob(response)
    }
    /// A separate display derivative. The supplied square remains the source of truth.
    public func submitExtension(_ image: Data, retryFailed: Bool = false, offline: Bool) async throws -> GeneratedArtworkJob {
        guard kind == .headerExtension, Self.isPNG(image) else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        struct Input: Encodable { let image: String; let aspect: String }
        var request = try connection.request(path: jobsPath, parameters: retryFailed ? [URLQueryItem(name: "retry_failed", value: "true")] : [])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Input(image: image.base64EncodedString(), aspect: "2:3"))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await jobsTransport.send(request)
        if response.status == 404 || response.status == 405 { throw GeneratedArtworkIssue.serverUpdateRequired }
        try checkJobResponse(response, accepted: [200, 202])
        return try decodeJob(response)
    }
    public func acknowledge(_ id: String, sha256: String, offline: Bool) async throws {
        guard kind == .headerExtension, GeneratedArtworkJob.validID(id), GeneratedArtworkJob.validID(sha256) else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        var request = try connection.request(path: "\(jobsPath)/\(id)/ack")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["sha256": sha256])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await jobsTransport.send(request)
        if response.status == 404 { throw MetadataLookupError.notFound }
        try checkJobResponse(response, accepted: [200, 204])
    }
    public static func isHeaderPNG(_ data: Data) -> Bool {
        guard (45...10_000_000).contains(data.count), data.starts(with: [137,80,78,71,13,10,26,10]),
              Array(data[12..<16]) == [73,72,68,82], data.suffix(12) == Data([0,0,0,0,73,69,78,68,174,66,96,130]) else { return false }
        func word(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) } }
        let width = word(16), height = word(20)
        // Integer canvases round the height up for odd-width square sources.
        return width > 0 && height <= 2048 && (UInt64(width) * 3 + 1) / 2 == UInt64(height)
    }
    public func job(_ id: String, offline: Bool) async throws -> GeneratedArtworkJob {
        guard GeneratedArtworkJob.validID(id) else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        let response = try await jobsTransport.send(connection.request(path: "\(jobsPath)/\(id)"))
        if response.status == 404 { throw MetadataLookupError.notFound }
        try checkJobResponse(response, accepted: [200])
        let value = try decodeJob(response)
        guard value.id == id else { throw MetadataLookupError.invalidResponse }
        return value
    }
    public func image(_ id: String, offline: Bool) async throws -> Data {
        guard GeneratedArtworkJob.validID(id) else { throw MetadataLookupError.invalidSearch }
        guard !offline else { throw MetadataLookupError.notCached }
        var request = try connection.request(path: "\(jobsPath)/\(id)/image")
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let response = try await imageTransport.send(request)
        if response.status == 404 || response.status == 409 { throw MetadataLookupError.notFound }
        try checkJobResponse(response, accepted: [200])
        guard response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "image/png",
              (kind == .square ? Self.isPNG(response.data) : Self.isHeaderPNG(response.data)) else { throw GeneratedArtworkIssue.invalidImage }
        return response.data
    }
    private func checkJobResponse(_ response: MetadataHTTPResponse, accepted: Set<Int>) throws {
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        guard accepted.contains(response.status) else {
            struct Failure: Decodable { let error: String }
            let failure = response.data.count <= 4096 ? try? JSONDecoder().decode(Failure.self, from: response.data) : nil
            throw GeneratedArtworkIssue.service(failure?.error ?? "unavailable")
        }
    }
    private func decodeJob(_ response: MetadataHTTPResponse) throws -> GeneratedArtworkJob {
        guard response.data.count <= 4096,
              response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MetadataLookupError.invalidResponse }
        let job = try JSONDecoder().decode(GeneratedArtworkJob.self, from: response.data)
        guard GeneratedArtworkJob.validID(job.id), (job.state == .failed) == (job.error != nil),
              job.error.map({ $0.utf8.count <= 80 }) ?? true else { throw MetadataLookupError.invalidResponse }
        return job
    }
    public func generate(_ input: GeneratedArtworkInput, offline: Bool) async throws -> Data {
        guard kind == .square, input.isValid else { throw MetadataLookupError.invalidSearch }
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
