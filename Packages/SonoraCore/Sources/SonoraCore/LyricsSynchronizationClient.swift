import CryptoKit
import Foundation

public struct LyricsSynchronizationResult: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case lrclib, elevenlabs, elevenlabsTranscription }
    public let text: String
    public let source: Source

    /// Require complete, ordered timing and the same edition/text when lyrics already exist.
    public static func catalog(text: String, existing: String, duration: Double) -> Self? {
        let document = LyricsDocument(text: text)
        let content = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.range(of: #"^\[(ar|al|ti|au|by|re|ve|length|offset):"#, options: [.regularExpression, .caseInsensitive]) == nil }
        guard !document.lines.isEmpty, document.lines.count == content.count,
              document.lines.allSatisfy({ $0.time.map { $0.isFinite && $0 >= 0 && $0 <= duration } ?? false }) else { return nil }
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
    static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}

public enum LyricsSynchronizationError: LocalizedError {
    case requiresLyrics, providerUnavailable, invalidAlignment, alreadyTimed, unsupportedDuration, noSpeech, noSpeechNotCached
    public var errorDescription: String? {
        switch self {
        case .alreadyTimed: "Esta letra ya tiene tiempos. Puedes ajustarlos en Editar letra."
        case .unsupportedDuration: "El análisis con ElevenLabs admite audio de entre un segundo y diez minutos."
        case .requiresLyrics: "No hay una letra sincronizada compatible. Añade primero la letra para poder sincronizarla con ElevenLabs."
        case .providerUnavailable: "ElevenLabs no está disponible. Comprueba que esté habilitado y que su API key esté configurada en el proxy."
        case .invalidAlignment: "Los tiempos recibidos no corresponden a esta letra o a este audio. No se ha cambiado la canción."
        case .noSpeech: "No se han encontrado palabras en el audio. Este resultado queda guardado para evitar repetir la transcripción."
        case .noSpeechNotCached: "No se han encontrado palabras en el audio y no se pudo guardar el resultado. Volver a intentarlo puede consumir créditos."
        }
    }
}

/// Catalog lookup never uploads audio. Paid work only runs after a genuine catalog miss;
/// known text is aligned, and missing text is transcribed. Every stage has persistent cache.
public actor LyricsSynchronizationClient {
    private let connection: MetadataProxyConnection
    private let cache: MetadataLookupCache
    private let transport: any MetadataLookupTransport
    private let diagnostics: MetadataDiagnostics
    private let lookup: MetadataLookupClient
    public init(connection: MetadataProxyConnection, cache: MetadataLookupCache, transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout: 180, resourceTimeout: 210), diagnostics: MetadataDiagnostics = .shared) {
        self.connection = connection; self.cache = cache; self.transport = transport
        self.diagnostics = diagnostics
        lookup = MetadataLookupClient(connection: connection, cache: cache, transport: transport)
    }
    public func synchronize(query: MetadataSearch, duration: Double, lyrics: String, offline: Bool,
                            audio: @Sendable () async throws -> Data) async throws -> MetadataLookupResult<LyricsSynchronizationResult> {
        guard duration.isFinite, duration > 0, duration <= 604800, lyrics.utf8.count <= 65_536, !lyrics.contains("\0") else { throw MetadataLookupError.invalidSearch }
        guard !LyricsDocument(text: lyrics).isTimed else { throw LyricsSynchronizationError.alreadyTimed }
        let wasAITranscribed = LyricsDocument(text: lyrics).isAITranscribed
        let wasAIRepaired = LyricsDocument(text: lyrics).isAIRepaired
        var knownText = LyricsDocument.removingInformation(from: lyrics)
        func attributed(_ result: MetadataLookupResult<LyricsSynchronizationResult>) -> MetadataLookupResult<LyricsSynchronizationResult> {
            let markers = (wasAITranscribed ? [LyricsDocument.aiTranscriptionMarker] : []) + (wasAIRepaired ? [LyricsDocument.aiRepairMarker] : [])
            guard !markers.isEmpty else { return result }
            return MetadataLookupResult(value: LyricsSynchronizationResult(text: (markers + [result.value.text]).joined(separator:"\n"), source: result.value.source), savedAt: result.savedAt, warning: result.warning)
        }
        var catalogFailure: MetadataLookupError?
        try Task.checkCancellation()
        if !query.title.isEmpty && !query.artist.isEmpty && !query.album.isEmpty {
            do {
                let found = try await lookup.lyrics(title: query.title, artist: query.artist, album: query.album, duration: max(1, Int(duration.rounded())), offline: offline)
                if !found.value.instrumental, abs(found.value.duration - duration) <= 2,
                   let timed = found.value.syncedLyrics,
                   let result = LyricsSynchronizationResult.catalog(text: timed, existing: knownText, duration: duration) {
                    return attributed(MetadataLookupResult(value: result, savedAt: found.savedAt, warning: found.warning))
                }
                // A stale catalog result after a network error is not proof of a fresh miss.
                if !offline && found.warning != nil { catalogFailure = .unavailable }
                if knownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !found.value.instrumental, abs(found.value.duration - duration) <= 2,
                   let plain = found.value.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard plain.utf8.count <= 65_536, !plain.contains("\0"), !LyricsDocument(text: plain).isTimed else { throw LyricsSynchronizationError.invalidAlignment }
                    knownText = LyricsDocument.removingInformation(from: plain)
                }
            } catch MetadataLookupError.notFound { }
              catch MetadataLookupError.notCached where offline { }
              catch MetadataLookupError.unavailable { catalogFailure = .unavailable }
        }
        // A failed catalog lookup allows local cache reads, never another paid operation.
        // An empty cache cannot contain an analysis, so avoid decoding audio in that case.
        if let catalogFailure, (try? await cache.size()) == 0 { throw catalogFailure }
        guard (1...600).contains(duration) else {
            if let catalogFailure { throw catalogFailure }
            throw LyricsSynchronizationError.unsupportedDuration
        }
        try Task.checkCancellation()
        let pcm = try await audio()
        try Task.checkCancellation()
        let pcmDuration = try Self.pcmDuration(pcm)
        do {
            let result: MetadataLookupResult<LyricsSynchronizationResult>
            let cacheOnly = offline || catalogFailure != nil
            if knownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let analysis = try await loadTranscription(audio: pcm, duration: pcmDuration, offline: cacheOnly)
                result = MetadataLookupResult(value: LyricsSynchronizationResult(text: LyricsDocument.aiTranscriptionMarker + "\n" + analysis.value.syncedText, source: .elevenlabsTranscription), savedAt: analysis.savedAt, warning: analysis.warning)
            } else {
                result = attributed(try await align(audio: pcm, lyrics: knownText, duration: pcmDuration, offline: cacheOnly))
            }
            if catalogFailure != nil {
                return MetadataLookupResult(value: result.value, savedAt: result.savedAt, warning: "No se pudo consultar LRCLIB. Se muestra el análisis guardado.")
            }
            return result
        } catch MetadataLookupError.notCached {
            if let catalogFailure { throw catalogFailure }
            throw MetadataLookupError.notCached
        }
    }
    /// Explicit whole-song analysis for repair. Existing lyrics never bias the transcript,
    /// and the cache identity is exactly the one used by the missing-lyrics fallback.
    public func transcription(duration: Double, offline: Bool, audio: @Sendable () async throws -> Data) async throws -> MetadataLookupResult<LyricsTranscript> {
        guard duration.isFinite, (1...600).contains(duration) else { throw LyricsSynchronizationError.unsupportedDuration }
        try Task.checkCancellation()
        let pcm = try await audio()
        try Task.checkCancellation()
        let actualDuration = try Self.pcmDuration(pcm)
        guard abs(actualDuration - duration) <= 0.1 else { throw LyricsSynchronizationError.invalidAlignment }
        return try await loadTranscription(audio: pcm, duration: actualDuration, offline: offline)
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
                  let valid = LyricsSynchronizationResult.catalog(text: value.synced_lyrics, existing: lyrics, duration: duration) else { throw LyricsSynchronizationError.invalidAlignment }
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
        let (response, result) = try await sendAudioRequest(request, decode: decode)
        let data = response.data
        do { try await cache.store(data, key: key, status: 200) }
        catch {
            await diagnostics.recordFailure(error, stage: .cacheWrite, requestID: response.requestID)
            return MetadataLookupResult(value: result, savedAt: nil, warning: "No se pudo guardar la sincronización para usarla sin conexión.")
        }
        return MetadataLookupResult(value: result, savedAt: nil, warning: nil)
    }
    private struct Transcription: Codable {
        let plain_lyrics: String
        let synced_lyrics: String
        let audio_sha256: String
        let duration: Double
        let model_id: String
        let words: [LyricsTranscript.Word]?
    }
    private func loadTranscription(audio: Data, duration: Double, offline: Bool) async throws -> MetadataLookupResult<LyricsTranscript> {
        let audioHash = Self.digest(audio)
        var request = try connection.request(path: "v1/lyrics/transcribe")
        guard let url = request.url else { throw MetadataLookupError.invalidConnection }
        let key = url.absoluteString + "#transcription-v1:scribe_v2:" + audioHash
        // A valid empty transcript is also a reusable result, never an automatic paid retry.
        func decode(_ data: Data) throws -> LyricsTranscript? {
            let value = try JSONDecoder().decode(MetadataProxyEnvelope<Transcription>.self, from: data).data
            guard value.audio_sha256 == audioHash, value.model_id == "scribe_v2",
                  value.duration.isFinite, abs(value.duration - duration) <= 0.1 else { throw LyricsSynchronizationError.invalidAlignment }
            if value.plain_lyrics.isEmpty && value.synced_lyrics.isEmpty { return nil }
            guard !value.plain_lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.plain_lyrics.utf8.count <= 65_536, !value.plain_lyrics.contains("\0"),
                  let valid = LyricsSynchronizationResult.catalog(text: value.synced_lyrics, existing: value.plain_lyrics, duration: duration) else { throw LyricsSynchronizationError.invalidAlignment }
            let transcript = LyricsTranscript(plainText: value.plain_lyrics, syncedText: valid.text, duration: duration, words: value.words?.isEmpty == true ? nil : value.words)
            try transcript.validateWords()
            return transcript
        }
        if let old = try await cache.read(key: key) {
            guard let result = try decode(old.data) else { throw LyricsSynchronizationError.noSpeech }
            return MetadataLookupResult(value: result, savedAt: old.savedAt, warning: nil)
        }
        if offline { throw MetadataLookupError.notCached }
        let boundary = "SonoraTranscription" + audioHash
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (response, result) = try await sendAudioRequest(request, maximumBytes: 8_000_000, decode: decode)
        let data = response.data
        var warning: String?
        do { try await cache.store(data, key: key, status: 200) }
        catch {
            await diagnostics.recordFailure(error, stage: .cacheWrite, requestID: response.requestID)
            warning = "No se pudo guardar la transcripción para usarla sin conexión."
        }
        guard let result else { throw warning == nil ? LyricsSynchronizationError.noSpeech : LyricsSynchronizationError.noSpeechNotCached }
        return MetadataLookupResult(value: result, savedAt: nil, warning: warning)
    }
    private func sendAudioRequest<Value>(_ request: URLRequest, maximumBytes: Int = 1_000_000, decode: (Data) throws -> Value) async throws -> (MetadataHTTPResponse, Value) {
        let response = try await transport.send(request)
        do {
            try Task.checkCancellation()
            guard response.status == 200 else { throw MetadataServiceFailure(response: response) }
            guard response.data.count <= maximumBytes else { throw MetadataLookupError.tooLarge }
            return (response, try decode(response.data))
        } catch {
            await diagnostics.recordFailure(error, stage: .responseValidation, requestID: response.requestID, httpStatus: response.status)
            throw error
        }
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
