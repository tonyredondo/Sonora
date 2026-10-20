import Foundation
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
        if #available(iOS 26.4, *) {
            // Timing edits do not change a translation. A content or language
            // change does. Regenerate older results that merged adjacent lines
            // because of punctuation or backward-aligned connecting words.
            struct TextLine: Encodable { let id: Int; let text: String }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try! encoder.encode(document.lines.map { TextLine(id: $0.id, text: $0.text) })
            return "apple-translation-context-v5:\(source):\(target):\(MusicToolsCache.digest(String(decoding: data, as: UTF8.self)))"
        }
        return legacyTranslationKey(document, source: source, target: target)
    }
    static func legacyTranslationKey(_ document: LyricsDocument, source: String, target: String) -> String {
        "apple-translation-v1:\(ProcessInfo.processInfo.operatingSystemVersionString):\(source):\(target):\(sourceKey(document))"
    }
    @MainActor static func interpret(_ document: LyricsDocument, language: String, cachedOnly: Bool = false, refresh: Bool = false,
                                    settings: MetadataAssistantSettings = .shared) async throws -> LyricsInterpretation {
        let offline = cachedOnly || settings.effectiveOffline
        if refresh && offline {
            throw MusicTextError.invalid("Conecta con el servidor y desactiva el modo sin conexión para actualizar el significado.")
        }
        // A local cache read must remain available when the keychain is locked.
        let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: offline ? "" : settings.savedToken())
        let client = LyricsInterpretationClient(connection: connection, cache: settings.cache)
        return try await client.interpret(lyrics: document.lines.map(\.text).joined(separator: "\n"), language: language,
                                          offline: offline, refresh: refresh)
    }
}
