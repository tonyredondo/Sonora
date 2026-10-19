import Foundation
import Observation
import SonoraCore

enum LyricUnderstanding {
    private struct SourceLine: Encodable { let id: Int; let time: Double?; let text: String }
    static func sourceKey(_ document: LyricsDocument) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Malformed LRC offsets can overflow to infinity. Cache identity must
        // remain deterministic without crashing while opening the lyrics view.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let data = try! encoder.encode(document.lines.map { SourceLine(id: $0.id, time: $0.time, text: $0.text) })
        return MusicToolsCache.digest(String(decoding: data, as: UTF8.self))
    }
    static func translationKey(_ document: LyricsDocument, source: String, target: String) -> String {
        "apple-translation-v1:\(ProcessInfo.processInfo.operatingSystemVersionString):\(source):\(target):\(sourceKey(document))"
    }
    @MainActor static func interpret(_ document: LyricsDocument, language: String, cachedOnly: Bool = false,
                                    settings: MetadataAssistantSettings = .shared) async throws -> LyricsInterpretation {
        let offline = cachedOnly || settings.effectiveOffline
        // A local cache read must remain available when the keychain is locked.
        let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: offline ? "" : settings.savedToken())
        let client = LyricsInterpretationClient(connection: connection, cache: settings.cache)
        return try await client.interpret(lyrics: document.lines.map(\.text).joined(separator: "\n"), language: language,
                                          offline: offline)
    }
}

@MainActor @Observable
final class LyricInterpretationModel {
    struct Request: Equatable {
        let id = UUID()
        let language: String
    }
    private(set) var explanation: String?
    private(set) var issue: String?
    private(set) var running = false
    @ObservationIgnored private var consumedRequest: UUID?
    @ObservationIgnored private var loadID = UUID()

    /// Language changes only read the cache. Each explicit request can generate
    /// once, for its selected language, even when SwiftUI restarts the task.
    func load(_ document: LyricsDocument, language: String, request: Request?,
              interpret: @MainActor (LyricsDocument, String, Bool) async throws -> LyricsInterpretation = {
                  try await LyricUnderstanding.interpret($0, language: $1, cachedOnly: $2)
              }) async {
        let id = UUID(); loadID = id
        let generate = request.map { $0.language == language && $0.id != consumedRequest } ?? false
        consumedRequest = request?.id
        explanation = nil; issue = nil; running = false
        do {
            let cached = try? await interpret(document, language, true)
            try Task.checkCancellation()
            guard loadID == id else { return }
            if let cached { explanation = cached.explanation; return }
            guard generate else { return }
            running = true
            let value = try await interpret(document, language, false)
            try Task.checkCancellation()
            guard loadID == id else { return }
            explanation = value.explanation; running = false
        } catch {
            guard loadID == id else { return }
            running = false
            if !Task.isCancelled, !(error is CancellationError) { issue = error.localizedDescription }
        }
    }
}
