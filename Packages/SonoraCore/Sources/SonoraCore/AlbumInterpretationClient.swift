import CryptoKit
import Foundation

/// Ordered album corpus. Missing lyrics stay explicit; no song is silently dropped.
/// LRC timing is deliberately excluded so retiming does not spend another request.
public struct AlbumInterpretationInput: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public let context: LyricsInterpretationContext
        public let lyrics: String
        public let genre: String
        public init(context: LyricsInterpretationContext, lyrics: String, genre: String = "") {
            self.context = context; self.lyrics = lyrics; self.genre = genre
        }
    }
    public let title: String
    public let artist: String
    public var tracks: [Track]
    public init(title: String, artist: String, tracks: [Track]) {
        self.title = title; self.artist = artist; self.tracks = tracks
    }
    public var missingLyrics: Int { tracks.filter { $0.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
    public var isValid: Bool {
        LyricsInterpretationContext(title: title, artist: artist).isValid
            && !tracks.isEmpty && tracks.count <= 100 && missingLyrics < tracks.count
            && tracks.reduce(0, { $0 + $1.lyrics.utf8.count }) <= 262144
            && tracks.allSatisfy { track in
                track.context.isValid && track.lyrics.utf8.count <= 65536
                    && track.genre.utf8.count <= 4096 && !track.genre.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && !track.lyrics.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && ![10, 13, 9].contains($0.value) }
            }
    }
    public var cacheIdentity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try! encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Album and song interpretations have independent versioned caches and share the same model.
public actor AlbumInterpretationClient {
    // New generation: regenerate previous readings once when adopting medium.
    public static let version = "codex-album-v2"
    private let connection: MetadataProxyConnection
    private let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache,
                transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 225, resourceTimeout: 240)) {
        self.connection = connection; self.cache = cache; self.transport = transport
    }
    public func interpret(_ album: AlbumInterpretationInput, language: String, offline: Bool, refresh: Bool = false) async throws -> LyricsInterpretation {
        guard album.isValid, ["es", "en", "fr", "de", "it", "pt"].contains(language) else { throw MetadataLookupError.invalidSearch }
        struct Input: Encodable { let album: AlbumInterpretationInput; let language: String; let effort: String; var refresh: Bool? }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Input(album: album, language: language, effort: LyricsInterpretationClient.effort))
        guard body.count <= 2 * 1024 * 1024 else { throw MetadataLookupError.invalidSearch }
        let key = "\(Self.version):gpt-6-astra:\(LyricsInterpretationClient.effort):\(connection.endpoint.absoluteString):" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        if !refresh, let old = try await cache.read(key: key), old.status == 200,
           let value = try? JSONDecoder().decode(LyricsInterpretation.self, from: old.data), value.isValid, value.effort == LyricsInterpretationClient.effort {
            try Task.checkCancellation(); return value
        }
        guard !offline else { throw MetadataLookupError.notCached }
        var request = try connection.request(path: "v1/albums/interpret")
        request.httpMethod = "POST"
        request.httpBody = refresh ? try encoder.encode(Input(album: album, language: language, effort: LyricsInterpretationClient.effort, refresh: true)) : body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        if response.status == 404 { throw LyricsInterpretationError.service("album_unavailable", nil) }
        guard response.status == 200 else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: response.data)
            throw LyricsInterpretationError.service(failure?.error ?? "unavailable", MetadataServiceFailure.reference(response.requestID))
        }
        guard response.data.count <= 131072 else { throw MetadataLookupError.tooLarge }
        let value = try JSONDecoder().decode(LyricsInterpretation.self, from: response.data)
        guard value.isValid, value.effort == LyricsInterpretationClient.effort else { throw MetadataLookupError.invalidResponse }
        try await cache.store(response.data, key: key, status: 200)
        return value
    }
}
