import Foundation
import NaturalLanguage
import Observation
import SonoraCore
@preconcurrency import Translation

enum LyricTranslationIssue: LocalizedError {
    case needsLanguages, sameLanguage, needsNewerSystem
    var errorDescription: String? {
        switch self {
        case .needsLanguages: "Descarga los idiomas una vez para traducir automáticamente y sin conexión."
        case .sameLanguage: "La letra ya está en el idioma elegido."
        case .needsNewerSystem: "La traducción automática con contexto necesita iOS 26.4 o posterior."
        }
    }
}

/// Translate one continuous text. Invisible links carry line identity through
/// Apple's word alignment, without inserting markers into the lyric itself.
enum ContextualLyricText {
    static func input(_ document: LyricsDocument) throws -> AttributedString {
        let lines = document.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty, lines.count <= 2000, lines.reduce(0, { $0 + $1.text.utf8.count }) <= 100000 else {
            throw MusicTextError.invalid("Esta letra está vacía o supera el límite de traducción (2000 frases o 100 KB).")
        }
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            var fragment = AttributedString(line.text + (index == lines.count - 1 ? "" : " "))
            fragment[AttributeScopes.FoundationAttributes.LinkAttribute.self] = link(line.id)
            text += fragment
        }
        return text
    }
    private static func link(_ id: Int) -> URL { URL(string: "sonora-lyric://line/\(id)")! }
    static func translation(_ text: AttributedString, document: LyricsDocument, targetLanguage: Locale.Language? = nil) throws -> LyricTranslation {
        let source = document.lines.filter { !$0.text.isEmpty }
        let identifiers = Dictionary(uniqueKeysWithValues: source.enumerated().map { (link($0.element.id), $0.offset) })
        let plainText = String(text.characters)
        // Spanish connecting words can align to an earlier verb even when they
        // sit inside the next phrase. Keep this narrow repair deterministic:
        // lexical-tagging assets are not available on every iOS installation.
        let connectors: Set<String> = ["a", "al", "de", "del", "en", "con", "sin", "por", "para",
                                       "y", "e", "o", "u", "que", "el", "la", "los", "las",
                                       "un", "una", "unos", "unas"]
        func containsOnlyConnectors(_ range: Range<String.Index>) -> Bool {
            guard targetLanguage?.languageCode?.identifier == "es",
                  let first = plainText[range].firstIndex(where: { !$0.isWhitespace }),
                  let last = plainText[range].lastIndex(where: { !$0.isWhitespace }) else { return false }
            // Alignment runs often include the separator after a word. Check
            // the word's own bounds, otherwise "a " is rejected before "ti".
            let end = plainText.index(after: last)
            guard first == plainText.startIndex || !plainText[plainText.index(before: first)].isLetter,
                  end == plainText.endIndex || !plainText[end].isLetter else { return false }
            let words = plainText[first..<end].split { $0.isWhitespace || $0.isPunctuation }
            return !words.isEmpty && words.allSatisfy { connectors.contains($0.lowercased()) }
        }
        struct Span {
            var first: Int
            var last: Int
            var text: String
        }
        var spans: [Span] = []
        var whitespace = ""
        let runs = Array(text.runs)
        for (position, run) in runs.enumerated() {
            let fragment = String(text[run.range].characters)
            let url = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]
            guard let url, let index = identifiers[url] else {
                // Apple may leave separators unaligned, but not translated words.
                guard url == nil, fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MusicTextError.invalid("Apple no pudo asociar la traducción con la letra. Reintenta para conservar la sincronización.")
                }
                whitespace += fragment
                continue
            }
            if fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                whitespace += fragment
                continue
            }
            var content = whitespace + fragment
            whitespace = ""
            if let previous = spans.last, index < previous.first,
               let next = runs.dropFirst(position + 1).first(where: { !text[$0.range].characters.allSatisfy(\.isWhitespace) }),
               next[AttributeScopes.FoundationAttributes.LinkAttribute.self].flatMap({ identifiers[$0] }) == previous.last,
               let lower = String.Index(run.range.lowerBound, within: plainText),
               let upper = String.Index(run.range.upperBound, within: plainText),
               containsOnlyConnectors(lower..<upper) {
                // Word alignment can send a connector back to the preceding
                // verb: "miss everyone / and you" -> "a todos / y [a] ti".
                // Keep that connector inside its surrounding translated line.
                // Content words (e.g. "red / car") still require a shared phrase.
                spans[spans.count - 1].text += content
                continue
            }
            if let previous = spans.last, index > previous.last {
                // Apple can align ". Next sentence" to the next source line.
                // Move only the closing punctuation back, keeping that line's
                // words and identity separate. Spanish ¿ and ¡ open the next line.
                let closing = content.prefix { $0.isWhitespace || ",.;:!?…".contains($0) }
                if closing.contains(where: { !$0.isWhitespace }) {
                    spans[spans.count - 1].text += closing
                    content = String(content.dropFirst(closing.count))
                    if content.isEmpty { continue }
                }
            }
            if let start = spans.firstIndex(where: { $0.last >= index }) {
                // Languages can reorder words across a line break ("red / car").
                // Join just those overlapping source lines, retaining target order.
                let merged = Span(first: min(index, spans[start].first), last: spans.last!.last,
                                  text: spans[start...].map(\.text).joined() + content)
                spans.replaceSubrange(start..., with: [merged])
            } else {
                spans.append(Span(first: index, last: index, text: content))
            }
        }
        guard !spans.isEmpty else {
            throw MusicTextError.invalid("Apple no devolvió correspondencias para la traducción. Vuelve a intentarlo.")
        }
        // Some source words have no separate target word ("We / are free").
        // Cover that gap with the following phrase, or the last phrase at EOF.
        // Every original line is accounted for; no timestamps or words are invented.
        var next = 0
        let phrases = spans.enumerated().map { index, span in
            let end = index == spans.count - 1 ? source.count - 1 : span.last
            let ids = source[next...end].map(\.id)
            next = end + 1
            return LyricTranslation.Phrase(lineIDs: ids, text: span.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try LyricTranslation(phrases: phrases, document: document)
    }
}

enum AppleLyricTranslator {
    @available(iOS 26.4, *)
    static func sourceLanguage(_ document: LyricsDocument, source: String) throws -> Locale.Language {
        if source != "auto" { return Locale.Language(identifier: source) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(document.lines.map(\.text).joined(separator: " "))
        guard let detected = recognizer.dominantLanguage else {
            throw MusicTextError.invalid("No se pudo detectar el idioma de la letra. Elige el idioma original en Traducción.")
        }
        return Locale.Language(identifier: detected.rawValue)
    }
    @MainActor static func translate(_ document: LyricsDocument, source: String, target: String) async throws -> LyricTranslation {
        guard #available(iOS 26.4, *) else { throw LyricTranslationIssue.needsNewerSystem }
        _ = try ContextualLyricText.input(document)
        let from = try sourceLanguage(document, source: source), to = Locale.Language(identifier: target)
        guard from.languageCode != to.languageCode else { throw LyricTranslationIssue.sameLanguage }
        let status = await LanguageAvailability().status(from: from, to: to)
        try Task.checkCancellation()
        switch status {
        case .installed: break
        case .supported: throw LyricTranslationIssue.needsLanguages
        case .unsupported: throw MusicTextError.invalid("Apple no admite esta combinación de idiomas. Elige otro idioma en Traducción.")
        @unknown default: throw MusicTextError.invalid("No se pudo comprobar la disponibilidad de los idiomas.")
        }
        let session = TranslationSession(installedSource: from, target: to)
        return try await translate(document, using: session)
    }
    @available(iOS 26.4, *)
    static func translate(_ document: LyricsDocument, using session: TranslationSession) async throws -> LyricTranslation {
        let input = try ContextualLyricText.input(document)
        let response = try await session.translate(input)
        try Task.checkCancellation()
        guard response.sourceText == String(input.characters), let result = response.attributedTargetText else {
            throw MusicTextError.invalid("Apple no devolvió una traducción sincronizada. Vuelve a intentarlo.")
        }
        return try ContextualLyricText.translation(result, document: document, targetLanguage: response.targetLanguage)
    }
}

@MainActor @Observable
final class LyricTranslationStore {
    typealias Translator = @MainActor (LyricsDocument, String, String) async throws -> LyricTranslation
    enum Status: Equatable {
        case queued, translating, ready, needsLanguages, sameLanguage, failed(String)
        var busy: Bool { self == .queued || self == .translating }
        var message: String {
            switch self {
            case .queued: "Traducción en cola…"
            case .translating: "Traduciendo la letra completa…"
            case .ready: "Traducción guardada"
            case .needsLanguages: LyricTranslationIssue.needsLanguages.localizedDescription
            case .sameLanguage: LyricTranslationIssue.sameLanguage.localizedDescription
            case .failed(let message): message
            }
        }
    }
    private(set) var results: [String: LyricTranslation] = [:]
    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let cache: MusicToolsCache
    @ObservationIgnored private let translate: Translator
    @ObservationIgnored private var pending: [String: Task<LyricTranslation, Error>] = [:]
    @ObservationIgnored private var tail: Task<LyricTranslation, Error>?
    @ObservationIgnored private var tailID: UUID?

    init(cache: MusicToolsCache = .shared, translate: @escaping Translator = {
        try await AppleLyricTranslator.translate($0, source: $1, target: $2)
    }) { self.cache = cache; self.translate = translate }

    func restore(_ document: LyricsDocument, source: String, target: String) async {
        let key = LyricUnderstanding.translationKey(document, source: source, target: target)
        guard results[key] == nil,
              let cached = try? await cache.read(LyricTranslation.self, key: key),
              let valid = try? cached.validated(for: document) else { return }
        guard results[key] == nil else { return }
        results[key] = valid
        if pending[key] == nil { statuses[key] = .ready }
    }

    /// The store owns each job, so changing songs or dismissing a sheet only
    /// detaches its observer. Cached songs bypass the serial translation queue.
    func load(_ document: LyricsDocument, source: String, target: String, refresh: Bool = false) async throws -> LyricTranslation {
        try Task.checkCancellation()
        let key = LyricUnderstanding.translationKey(document, source: source, target: target)
        if !refresh {
            await restore(document, source: source, target: target)
            if let value = results[key] { return value }
        }
        try Task.checkCancellation()
        if pending[key] == nil {
            let id = UUID(), predecessor = tail
            statuses[key] = .queued
            let job = Task { [self] in
                defer {
                    pending[key] = nil
                    if tailID == id { tail = nil; tailID = nil }
                }
                _ = await predecessor?.result
                statuses[key] = .translating
                do {
                    let value = try await translate(document, source, target)
                    let valid = try value.validated(for: document)
                    try await cache.write(valid, key: key)
                    results[key] = valid; statuses[key] = .ready
                    return valid
                } catch {
                    switch error {
                    case LyricTranslationIssue.needsLanguages: statuses[key] = .needsLanguages
                    case LyricTranslationIssue.sameLanguage: statuses[key] = .sameLanguage
                    default: statuses[key] = .failed(error.localizedDescription)
                    }
                    throw error
                }
            }
            pending[key] = job; tail = job; tailID = id
        }
        let result = try await pending[key]!.value
        try Task.checkCancellation()
        return result
    }
}
