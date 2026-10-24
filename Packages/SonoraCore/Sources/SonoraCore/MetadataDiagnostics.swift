import Foundation
import OSLog

/// Only typed, bounded diagnostic fields are retained; server messages and URL queries are never logged.
public struct MetadataServiceFailure: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String?
    public let provider: String?
    public let upstreamStatus: Int?
    public let reason: String?
    public let requestID: String?

    private struct Payload: Decodable {
        let error: String?
        let provider: String?
        let upstream_status: Int?
        let reason: String?
        let request_id: String?
    }
    static func reference(_ value: String?) -> String? { value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() }
    public init(response: MetadataHTTPResponse, requestID: String? = nil) {
        let body = response.data.count <= 16_384 ? try? JSONDecoder().decode(Payload.self, from: response.data) : nil
        status = response.status
        let codes: Set<String> = ["invalid_input", "too_large", "queue_full", "deadline_exceeded", "not_found", "provider_unavailable", "service_unavailable", "upstream_error", "unauthorized", "invalid_metadata", "metadata_conflict", "metadata_storage_full", "metadata_storage_unavailable"]
        let providers: Set<String> = ["musicbrainz", "acoustid", "cover_art", "lrclib", "elevenlabs"]
        let reasons: Set<String> = ["quota_exceeded", "invalid_api_key", "missing_permissions", "rate_limit_exceeded", "concurrent_limit_exceeded", "system_busy", "http_status", "upstream_timeout", "upstream_connect", "upstream_body", "upstream_decode", "upstream_transport", "invalid_provider_response", "proxy_deadline", "cache_io", "configuration", "queue_full", "worker_unavailable", "invalid_input", "upload_too_large", "response_too_large", "provider_disabled", "provider_not_configured", "not_found"]
        code = body?.error.flatMap { codes.contains($0) ? $0 : nil }
        provider = body?.provider.flatMap { providers.contains($0) ? $0 : nil }
        reason = body?.reason.flatMap { reasons.contains($0) ? $0 : nil }
        upstreamStatus = body?.upstream_status.flatMap { (100...599).contains($0) ? $0 : nil }
        self.requestID = Self.reference(response.requestID) ?? Self.reference(body?.request_id) ?? Self.reference(requestID)
    }
    public var errorDescription: String? {
        let service = ["elevenlabs":"El servicio de análisis", "musicbrainz":"MusicBrainz", "lrclib":"LRCLIB", "cover_art":"Cover Art Archive", "acoustid":"AcoustID"][provider ?? ""] ?? "El servidor"
        let message: String
        switch reason ?? code {
        case "quota_exceeded": message = "\(service) indica que se ha agotado la cuota de la cuenta."
        case "upstream_timeout", "proxy_deadline", "deadline_exceeded": message = "Se agotó el tiempo de espera del análisis."
        case "upstream_connect": message = "El servidor no pudo conectar con el proveedor."
        case "unauthorized": message = "El servidor rechazó la autenticación de Sonora."
        case "invalid_api_key", "missing_permissions": message = "\(service) rechazó las credenciales o los permisos del servicio."
        case "queue_full", "rate_limit_exceeded", "concurrent_limit_exceeded", "system_busy": message = "\(service) está ocupado o ha alcanzado su límite de peticiones."
        case "invalid_provider_response": message = "\(service) devolvió un análisis que no se pudo validar."
        default: message = "\(service) no pudo completar la consulta."
        }
        var details = ["HTTP \(status)"]
        if let upstreamStatus { details.append("proveedor HTTP \(upstreamStatus)") }
        if let code { details.append(code) }
        if let reason { details.append(reason) }
        return message + "\n" + details.joined(separator: " · ") + (requestID.map { "\nReferencia: \($0)" } ?? "")
    }
}

public enum MetadataDiagnosticStage: String, Sendable {
    case network, responseValidation, cacheWrite, lyricsLoad, lyricsAnalysis, lyricsComparison, lyricsSave
}

/// A sanitized URLSession failure that consumers can recognize without retaining URLs or credentials.
public struct MetadataTransportFailure: LocalizedError, Sendable {
    public let code: Int
    public let requestID: String
    public var errorDescription: String? {
        let message = code == URLError.timedOut.rawValue ? "Se agotó el tiempo de espera al conectar con el servidor." : "No se pudo completar la conexión con el servidor."
        return "\(message)\nNSURLErrorDomain \(code)\nReferencia: \(requestID)"
    }
}

/// Two private JSONL files survive relaunch. Logging failures never replace the original operation error.
public actor MetadataDiagnostics {
    public static let shared = MetadataDiagnostics(directory: URL.applicationSupportDirectory.appendingPathComponent("Sonora/Diagnostics", isDirectory: true))
    private let directory: URL
    private let maxBytes: Int
    private let logger = Logger(subsystem: "com.tonyredondo.Sonora", category: "diagnostics")
    private static let errorDomains: Set<String> = [
        NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
        "kCFErrorDomainCFNetwork", "AVFoundationErrorDomain", "com.apple.coreaudio.avfaudio",
        "org.sbooth.AudioEngine.AudioPlayer", "org.sbooth.AudioEngine.AudioFile",
        "org.sbooth.AudioEngine.AudioDecoder", "org.sbooth.AudioEngine.DSDDecoder",
        "org.sbooth.AudioEngine.AudioConverter", "org.sbooth.AudioEngine.AudioExporter",
        "org.sbooth.AudioEngine.AudioEncoder", "org.sbooth.AudioEngine.InputSource",
        "org.sbooth.AudioEngine.OutputTarget", "org.sbooth.AudioEngine.ReplayGainAnalyzer"
    ]
    public init(directory: URL, maxBytes: Int = 1_048_576) {
        self.directory = directory
        self.maxBytes = max(512, min(1_048_576, maxBytes))
    }

    func recordHTTP(request: URLRequest, response: MetadataHTTPResponse? = nil, error: Error? = nil, elapsed: TimeInterval) {
        var fields = base(stage: .network, error: error)
        fields["request_id"] = MetadataServiceFailure.reference(request.value(forHTTPHeaderField: "X-Sonora-Request-ID"))
        fields["operation"] = Self.operation(request.url)
        fields["method"] = ["GET", "POST", "PUT", "DELETE", "HEAD"].contains(request.httpMethod ?? "") ? request.httpMethod : "OTHER"
        fields["elapsed_ms"] = String(Int(max(0, elapsed) * 1000))
        if let response {
            let failure = MetadataServiceFailure(response: response, requestID: fields["request_id"])
            fields["http_status"] = String(response.status)
            fields["request_id"] = failure.requestID
            fields["provider"] = failure.provider; fields["reason"] = failure.reason; fields["server_code"] = failure.code
            fields["upstream_status"] = failure.upstreamStatus.map(String.init)
        }
        write(fields)
    }

    public func recordFailure(_ error: Error, stage: MetadataDiagnosticStage, requestID: String? = nil, httpStatus: Int? = nil) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        var fields = base(stage: stage, error: error)
        fields["request_id"] = MetadataServiceFailure.reference(requestID)
        fields["http_status"] = httpStatus.map(String.init)
        if let failure = error as? MetadataServiceFailure {
            fields["request_id"] = failure.requestID; fields["http_status"] = String(failure.status)
            fields["provider"] = failure.provider; fields["reason"] = failure.reason; fields["server_code"] = failure.code
            fields["upstream_status"] = failure.upstreamStatus.map(String.init)
        } else if let failure = error as? MetadataTransportFailure {
            fields["request_id"] = failure.requestID; fields["error_code"] = String(failure.code)
            fields["error_domain"] = NSURLErrorDomain
        }
        write(fields)
    }

    private func base(stage: MetadataDiagnosticStage, error: Error?) -> [String: String] {
        var fields = ["timestamp": ISO8601DateFormatter().string(from: Date()), "stage": stage.rawValue, "event_id": UUID().uuidString.lowercased()]
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String { fields["app_build"] = String(build.prefix(32)) }
        if let error {
            fields["error_type"] = String(String(reflecting: type(of: error)).prefix(160))
            var cause = error as NSError
            // Bound nested causes and retain only known domains/numeric codes, never userInfo text.
            for depth in 0...3 {
                let prefix = depth == 0 ? "error" : "underlying_\(depth)"
                fields[prefix + "_code"] = String(cause.code)
                if Self.errorDomains.contains(cause.domain) { fields[prefix + "_domain"] = cause.domain }
                guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                cause = underlying
            }
            if error is LyricsRepairError || error is LyricsSynchronizationError || error is MetadataLookupError {
                fields["reason"] = String(describing: error)
            }
            if let error = error as? DecodingError {
                let context: DecodingError.Context
                switch error {
                case .dataCorrupted(let value): fields["reason"] = "data_corrupted"; context = value
                case .keyNotFound(_, let value): fields["reason"] = "missing_key"; context = value
                case .typeMismatch(_, let value): fields["reason"] = "type_mismatch"; context = value
                case .valueNotFound(_, let value): fields["reason"] = "missing_value"; context = value
                @unknown default: return fields
                }
                let known: Set<String> = ["data", "words", "text", "start", "end", "plain_lyrics", "synced_lyrics", "audio_sha256", "duration", "model_id", "language_code"]
                fields["coding_path"] = context.codingPath.prefix(12).map { $0.intValue.map { "[\($0)]" } ?? (known.contains($0.stringValue) ? $0.stringValue : "*") }.joined(separator: ".")
            }
        }
        return fields
    }

    private static func operation(_ url: URL?) -> String {
        let parts = url?.pathComponents ?? []
        guard let index = parts.lastIndex(of: "v1"), index + 1 < parts.count else { return "other" }
        let tail = Array(parts[(index + 1)...])
        switch tail.first {
        case "lyrics": return tail.count == 1 ? "lyrics" : (["align", "transcribe"].contains(tail[1]) ? "lyrics/" + tail[1] : "other")
        case "recordings", "releases", "artwork", "jobs", "audio", "metadata-records", "identify", "status": return tail[0]
        default: return "other"
        }
    }

    private func write(_ fields: [String: String]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]); data.append(10)
            guard data.count <= maxBytes else { return }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("errors.jsonl"), previous = directory.appendingPathComponent("errors.previous.jsonl")
            let size = ((try? fm.attributesOfItem(atPath: current.path)[.size]) as? NSNumber)?.intValue ?? 0
            if size + data.count > maxBytes {
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: current, to: previous)
            }
            if !fm.fileExists(atPath: current.path) {
                guard fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            logger.error("\(String(decoding: data, as: UTF8.self), privacy: .public)")
        } catch {
            logger.error("Diagnostic file write failed: \((error as NSError).code, privacy: .public)")
        }
    }
}
