import Foundation
import CryptoKit

/// A connection is deliberately not Codable or printable: its token stays out of cache files.
public struct MetadataProxyConnection: Sendable {
    public let endpoint: URL
    private let token: String
    public init(endpoint: String, token: String) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(),
              !host.isEmpty, !["0.0.0.0", "::", "[::]"].contains(host), url.port.map({ (1...65535).contains($0) }) ?? true,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && Self.local(host)),
              token.utf8.count <= 512, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw MetadataLookupError.invalidConnection }
        self.endpoint = url; self.token = token
    }
    private static func local(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        guard components.count == 4, octets.count == 4 else { return false }
        return octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
    func request(path: String, parameters: [URLQueryItem] = []) throws -> URLRequest {
        var parts = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !parameters.isEmpty { parts?.queryItems = parameters.sorted { $0.name < $1.name } }
        guard let url = parts?.url else { throw MetadataLookupError.invalidConnection }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
}

public struct MetadataHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let contentType: String?
    public let requestID: String?
    public init(data: Data, status: Int, contentType: String?, requestID: String? = nil) {
        self.data = data; self.status = status; self.contentType = contentType; self.requestID = requestID
    }
}
public protocol MetadataLookupTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse
}
public struct MetadataURLSessionTransport: MetadataLookupTransport {
    private let session: URLSession
    private let diagnostics: MetadataDiagnostics
    public init(requestTimeout: TimeInterval = 75, resourceTimeout: TimeInterval = 90, diagnostics: MetadataDiagnostics = .shared) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout; config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = true; config.urlCache = nil
        session = URLSession(configuration: config)
        self.diagnostics = diagnostics
    }
    public init(session: URLSession, diagnostics: MetadataDiagnostics = .shared) {
        self.session = session; self.diagnostics = diagnostics
    }
    public func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        var request = request
        let reference = MetadataServiceFailure.reference(request.value(forHTTPHeaderField: "X-Sonora-Request-ID")) ?? UUID().uuidString.lowercased()
        request.setValue(reference, forHTTPHeaderField: "X-Sonora-Request-ID")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await session.data(for: request, delegate: MetadataRedirectBlocker())
            guard let response = response as? HTTPURLResponse else { throw MetadataLookupError.invalidResponse }
            let value = MetadataHTTPResponse(data: data, status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"), requestID: MetadataServiceFailure.reference(response.value(forHTTPHeaderField: "X-Sonora-Request-ID")) ?? reference)
            if !(200...299).contains(value.status) {
                await diagnostics.recordHTTP(request: request, response: value, elapsed: ProcessInfo.processInfo.systemUptime - started)
            }
            return value
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            await diagnostics.recordHTTP(request: request, error: error, elapsed: ProcessInfo.processInfo.systemUptime - started)
            if let error = error as? URLError { throw MetadataTransportFailure(code: error.code.rawValue, requestID: reference) }
            throw error
        }
    }
}

/// The configured endpoint must answer directly; a redirect must never receive its bearer token.
private final class MetadataRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct MetadataLookupResult<Value: Sendable>: Sendable {
    public let value: Value
    public let savedAt: Date?
    public let warning: String?
    public var isCached: Bool { savedAt != nil }
}
public struct MetadataProxyStatus: Decodable, Sendable {
    public let providers: [String: Capability]
    public struct Capability: Decodable, Sendable { public let enabled: Bool; public let configured: Bool }
}

public actor MetadataLookupClient {
    private let connection: MetadataProxyConnection
    public let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache, transport: any MetadataLookupTransport = MetadataURLSessionTransport()) {
        self.connection = connection; self.cache = cache; self.transport = transport
    }
    public func search(_ query: MetadataSearch, offline: Bool, refresh: Bool = false) async throws -> MetadataLookupResult<[MetadataRecording]> {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, [title, query.artist, query.album].allSatisfy({ $0.utf8.count <= 1024 && !$0.contains("\0") }) else { throw MetadataLookupError.invalidSearch }
        let parameters = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: query.artist.trimmingCharacters(in: .whitespacesAndNewlines)), URLQueryItem(name: "album", value: query.album.trimmingCharacters(in: .whitespacesAndNewlines))]
        return try await fetch(path: "v1/recordings", parameters: parameters, offline: offline, refresh: refresh) { data in
            try JSONDecoder().decode(MetadataProxyEnvelope<[MetadataRecording]>.self, from: data).data
        }
    }
    public func release(_ id: String, offline: Bool) async throws -> MetadataLookupResult<MetadataRelease> {
        try validateID(id)
        return try await fetch(path: "v1/releases/" + id, offline: offline) { try JSONDecoder().decode(MetadataProxyEnvelope<MetadataRelease>.self, from: $0).data }
    }
    public func recording(_ id: String, offline: Bool) async throws -> MetadataLookupResult<MetadataRecording> {
        try validateID(id)
        return try await fetch(path: "v1/recordings/" + id, offline: offline) { try JSONDecoder().decode(MetadataProxyEnvelope<MetadataRecording>.self, from: $0).data }
    }
    public func identify(fingerprint: String, duration: Int, offline: Bool) async throws -> MetadataLookupResult<MetadataIdentification> {
        guard duration > 0, duration <= 86400, !fingerprint.isEmpty, fingerprint.utf8.count <= 100_000,
              fingerprint.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else { throw MetadataLookupError.invalidSearch }
        var request = try connection.request(path: "v1/identify")
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Input: Encodable { let fingerprint: String; let duration: Int }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(Input(fingerprint: fingerprint, duration: duration))
        return try await fetch(request: request, offline: offline, maxAge: 30 * 86400) {
            let value = try JSONDecoder().decode(MetadataProxyEnvelope<MetadataIdentification>.self, from: $0).data
            guard value.status == "ok" else { throw MetadataLookupError.invalidResponse }
            return value
        }
    }
    public func lyrics(title: String, artist: String, album: String, duration: Int, offline: Bool) async throws -> MetadataLookupResult<MetadataLyrics> {
        guard duration > 0, !title.isEmpty, !artist.isEmpty, !album.isEmpty else { throw MetadataLookupError.invalidSearch }
        return try await fetch(path: "v1/lyrics", parameters: [URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "album", value: album), URLQueryItem(name: "duration", value: String(duration))], offline: offline, maxAge: 30 * 86400) { try JSONDecoder().decode(MetadataProxyEnvelope<MetadataLyrics>.self, from: $0).data }
    }
    public func artwork(_ id: String, offline: Bool) async throws -> MetadataLookupResult<Data> {
        try validateID(id)
        return try await fetch(path: "v1/artwork/" + id, offline: offline, maxAge: 90 * 86400) { data in
            guard !data.isEmpty else { throw MetadataLookupError.invalidResponse }; return data
        }
    }
    /// Status is never cached: this verifies the configured token against a protected route.
    public func status() async throws -> MetadataProxyStatus {
        let response = try await transport.send(connection.request(path: "v1/status"))
        try check(response.status)
        return try JSONDecoder().decode(MetadataProxyStatus.self, from: response.data)
    }
    private func validateID(_ id: String) throws {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw MetadataLookupError.invalidSearch }
    }
    private func check(_ status: Int) throws {
        if status == 401 || status == 403 { throw MetadataLookupError.unauthorized }
        if status == 404 { throw MetadataLookupError.notFound }
        guard status == 200 else { throw MetadataLookupError.unavailable }
    }
    private func fetch<Value: Sendable>(path: String, parameters: [URLQueryItem] = [], offline: Bool, refresh: Bool = false, maxAge: TimeInterval = 7 * 86400, decode: @Sendable (Data) throws -> Value) async throws -> MetadataLookupResult<Value> {
        try await fetch(request: connection.request(path: path, parameters: parameters), offline: offline, refresh: refresh, maxAge: maxAge, decode: decode)
    }
    private func fetch<Value: Sendable>(request: URLRequest, offline: Bool, refresh: Bool = false, maxAge: TimeInterval, decode: @Sendable (Data) throws -> Value) async throws -> MetadataLookupResult<Value> {
        try Task.checkCancellation()
        guard let url = request.url else { throw MetadataLookupError.invalidConnection }
        // POST bodies contain fingerprints, never audio. Their digest separates cached lookups.
        let key = url.absoluteString + (request.httpBody.map { "#" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "")
        let old = try await cache.read(key: key)
        try Task.checkCancellation()
        if let old, offline || (!refresh && Date().timeIntervalSince(old.savedAt) < (old.status == 404 ? 300 : maxAge)) {
            try check(old.status)
            return MetadataLookupResult(value: try decode(old.data), savedAt: old.savedAt, warning: nil)
        }
        guard !offline else { throw MetadataLookupError.notCached }
        do {
            let response = try await transport.send(request)
            try Task.checkCancellation()
            // A fresh miss remains authoritative when its optional cache write fails.
            if response.status == 404 { try? await cache.store(Data(), key: key, status: 404) }
            try check(response.status)
            guard response.data.count <= 10_000_000 else { throw MetadataLookupError.tooLarge }
            let value = try decode(response.data)
            var warning: String?
            do { try await cache.store(response.data, key: key, status: 200) }
            catch { warning = MetadataLookupError.cacheUnavailable.localizedDescription }
            return MetadataLookupResult(value: value, savedAt: nil, warning: warning)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch MetadataLookupError.unauthorized { throw MetadataLookupError.unauthorized }
        catch MetadataLookupError.notFound { throw MetadataLookupError.notFound }
        catch {
            if let old, old.status == 200 {
                return MetadataLookupResult(value: try decode(old.data), savedAt: old.savedAt, warning: "No se pudo actualizar. Se muestra la copia guardada.")
            }
            if let error = error as? MetadataLookupError { throw error }
            if error is DecodingError { throw MetadataLookupError.invalidResponse }
            throw MetadataLookupError.unavailable
        }
    }
}
