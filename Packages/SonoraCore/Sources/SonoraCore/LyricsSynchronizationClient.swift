import CryptoKit
import Foundation

public struct LyricsSynchronizationResult: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case lrclib, elevenlabs }
    public let text: String
    public let source: Source

    /// Require complete, ordered timing and the same edition/text when lyrics already exist.
    public static func catalog(text: String, existing: String, duration: Double) -> Self? {
        let document = LyricsDocument(text: text)
        let content = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.range(of: #"^\[(ar|al|ti|au|by|re|ve|length|offset):"#, options: [.regularExpression, .caseInsensitive]) == nil }
        guard !document.lines.isEmpty, document.lines.count == content.count else { return nil }
        var previous = 0.0
        for raw in content {
            let parsed = LyricsDocument(text: raw).lines
            guard parsed.count == 1, let time = parsed.first?.time, time.isFinite, time >= previous, time <= duration else { return nil }
            previous = time
        }
        let original = existing.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !original.isEmpty {
            guard original.map(normalized) == document.lines.map({ normalized($0.text) }) else { return nil }
            var index = 0
            let preserved = existing.components(separatedBy: .newlines).map { line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                defer { index += 1 }
                let ticks = Int(((document.lines[index].time ?? 0) * 100).rounded(.down))
                return String(format: "[%02d:%02d.%02d]", ticks / 6000, ticks / 100 % 60, ticks % 100) + line
            }.joined(separator: "\n")
            return Self(text: preserved, source: .lrclib)
        }
        return Self(text: text, source: .lrclib)
    }
    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}

public enum LyricsSynchronizationError: LocalizedError {
    case requiresLyrics, providerUnavailable, invalidAlignment, alreadyTimed, unsupportedDuration
    public var errorDescription: String? {
        switch self {
        case .alreadyTimed: "Esta letra ya tiene tiempos. Puedes ajustarlos en Editar letra."
        case .unsupportedDuration: "La sincronización con ElevenLabs admite audio de entre un segundo y diez minutos."
        case .requiresLyrics: "No hay una letra sincronizada compatible. Añade primero la letra para poder sincronizarla con ElevenLabs."
        case .providerUnavailable: "ElevenLabs no está disponible. Comprueba que esté habilitado y que su API key esté configurada en el proxy."
        case .invalidAlignment: "Los tiempos recibidos no corresponden a esta letra o a este audio. No se ha cambiado la canción."
        }
    }
}

/// Catalog lookup never uploads audio. Forced alignment only runs after a genuine catalog miss.
public actor LyricsSynchronizationClient {
    private let connection: MetadataProxyConnection
    private let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    private let lookup: MetadataLookupClient
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache, transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 180, resourceTimeout: 210)) {
        self.connection = connection; self.cache = cache; self.transport = transport
        lookup = MetadataLookupClient(connection: connection, cache: cache, transport: transport)
    }
    public func synchronize(query: MetadataSearch, duration: Double, lyrics: String, offline: Bool,
                            audio: @Sendable () async throws -> Data) async throws -> MetadataLookupResult<LyricsSynchronizationResult> {
        guard duration.isFinite, duration > 0, duration <= 604800, lyrics.utf8.count <= 65_536, !lyrics.contains("\0") else { throw MetadataLookupError.invalidSearch }
        guard !LyricsDocument(text: lyrics).isTimed else { throw LyricsSynchronizationError.alreadyTimed }
        try Task.checkCancellation()
        if !query.title.isEmpty && !query.artist.isEmpty && !query.album.isEmpty {
            do {
                let found = try await lookup.lyrics(title: query.title, artist: query.artist, album: query.album, duration: max(1, Int(duration.rounded())), offline: offline)
                if !found.value.instrumental, abs(found.value.duration - duration) <= 2,
                   let timed = found.value.syncedLyrics,
                   let result = LyricsSynchronizationResult.catalog(text: timed, existing: lyrics, duration: duration) {
                    return MetadataLookupResult(value: result, savedAt: found.savedAt, warning: found.warning)
                }
                // A stale catalog result after a network error is not proof of a fresh miss.
                if !offline && found.warning != nil { throw MetadataLookupError.unavailable }
            } catch MetadataLookupError.notFound { }
              catch MetadataLookupError.notCached where offline { }
        }
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LyricsSynchronizationError.requiresLyrics }
        guard (1...600).contains(duration) else { throw LyricsSynchronizationError.unsupportedDuration }
        try Task.checkCancellation()
        let pcm = try await audio()
        try Task.checkCancellation()
        let pcmDuration = try Self.pcmDuration(pcm)
        return try await align(audio: pcm, lyrics: lyrics, duration: pcmDuration, offline: offline)
    }
    private struct Alignment: Codable {
        let plain_lyrics: String
        let synced_lyrics: String
        let audio_sha256: String
        let text_sha256: String
        let duration: Double
    }
    private func align(audio: Data, lyrics: String, duration: Double, offline: Bool) async throws -> MetadataLookupResult<LyricsSynchronizationResult> {
        let audioHash = Self.digest(audio), textHash = Self.digest(Data(lyrics.utf8))
        var request = try connection.request(path: "v1/lyrics/align")
        guard let url = request.url else { throw MetadataLookupError.invalidConnection }
        let key = url.absoluteString + "#alignment-v1:" + audioHash + ":" + textHash
        func decode(_ data: Data) throws -> LyricsSynchronizationResult {
            let value = try JSONDecoder().decode(MetadataProxyEnvelope<Alignment>.self, from: data).data
            guard value.audio_sha256 == audioHash, value.text_sha256 == textHash, value.plain_lyrics == lyrics,
                  value.duration.isFinite, abs(value.duration - duration) <= 0.1,
                  let valid = LyricsSynchronizationResult.catalog(text: value.synced_lyrics, existing: lyrics, duration: value.duration) else { throw LyricsSynchronizationError.invalidAlignment }
            return LyricsSynchronizationResult(text: valid.text, source: .elevenlabs)
        }
        // Immutable analysis is reused until explicitly cleared/evicted, including after relaunch.
        if let old = try await cache.read(key: key) {
            return MetadataLookupResult(value: try decode(old.data), savedAt: old.savedAt, warning: nil)
        }
        if offline { throw MetadataLookupError.notCached }
        let boundary = "SonoraAlignment" + audioHash + textHash
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\n\(lyrics)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        if response.status == 401 || response.status == 403 { throw MetadataLookupError.unauthorized }
        if response.status == 503 { throw LyricsSynchronizationError.providerUnavailable }
        guard response.status == 200 else { throw MetadataLookupError.unavailable }
        guard response.data.count <= 1_000_000 else { throw MetadataLookupError.tooLarge }
        let result = try decode(response.data)
        do { try await cache.store(response.data, key: key, status: 200) }
        catch { return MetadataLookupResult(value: result, savedAt: nil, warning: "No se pudo guardar la sincronización para usarla sin conexión.") }
        return MetadataLookupResult(value: result, savedAt: nil, warning: nil)
    }
    private static func pcmDuration(_ audio: Data) throws -> Double {
        guard (32_044...19_200_044).contains(audio.count), (audio.count - 44).isMultiple(of: 2) else { throw MetadataLookupError.tooLarge }
        let header = Array(audio.prefix(44)), size = audio.count - 44
        func uint32(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 | Int(header[offset + $1]) << ($1 * 8) } }
        guard String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: header[8..<16], as: UTF8.self) == "WAVEfmt ",
              Array(header[16..<36]) == [16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0],
              String(decoding: header[36..<40], as: UTF8.self) == "data", uint32(4) == size + 36, uint32(40) == size else { throw LyricsSynchronizationError.invalidAlignment }
        return Double(size) / 32000
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
