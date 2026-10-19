import SonoraCore
import SwiftUI
// iOS 18 Translation sessions lack Sendable annotations. A session belongs to one
// translationTask, is used sequentially and is never shared with another task.
@preconcurrency import Translation

struct LyricUnderstandingView: View {
    let document: LyricsDocument
    let translation: LyricTranslation?
    let applyTranslation: (LyricTranslation?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Herramienta de letra", selection: $mode) {
                    Text("Significado").tag(0)
                    Text("Traducción").tag(1)
                }.pickerStyle(.segmented).padding()
                if mode == 0 { LyricInterpretationView(document: document) }
                else if #available(iOS 18.0, *) {
                    LyricTranslationView(document: document, hasTranslation: translation != nil) { value in applyTranslation(value); dismiss() }
                } else {
                    ContentUnavailableView("Necesita iOS 18", systemImage: "character.bubble", description: Text("La traducción local está disponible a partir de iOS 18."))
                }
            }.navigationTitle("Comprender letra").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
        }
    }
}

private struct LyricInterpretationView: View {
    let document: LyricsDocument
    @State private var model = LyricInterpretationModel()
    @State private var request: LyricInterpretationModel.Request?

    @AppStorage("lyricMeaningLanguage") private var language = "es"
    var body: some View {
        List {
            Section {
                Picker("Idioma de respuesta", selection: $language) {
                    Text("Español").tag("es"); Text("English").tag("en"); Text("Français").tag("fr")
                    Text("Deutsch").tag("de"); Text("Italiano").tag("it"); Text("Português").tag("pt")
                }.disabled(model.running).accessibilityIdentifier("interpretationLanguage")
                if model.running { ProgressView("Interpretando con Codex…"); Button("Cancelar") { request = nil } }
                else {
                    Button(model.explanation == nil ? "Interpretar letra" : "Ver interpretación guardada", systemImage: "sparkles") { request = .init(language: language) }
                        .accessibilityIdentifier("interpretLyrics")
                }

                if let issue = model.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("interpretationIssue") }
            } footer: { Text("Interpretación de IA · GPT Astra. Es una lectura posible, no una explicación confirmada por su autor. Un análisis nuevo envía la letra a Codex desde tu servidor y consume uso de tu plan. Las interpretaciones guardadas funcionan sin conexión.") }
            if document.isAITranscribed { Section { Text("Esta letra fue transcrita por IA y puede contener errores que afecten a la interpretación.").font(.footnote) } }
            if let explanation = model.explanation { Section("Interpretación de IA") { Text(explanation).textSelection(.enabled).accessibilityIdentifier("lyricInterpretation") } }
        }
        .compactContentSpacing()
        .task(id: "\(language):\(request?.id.uuidString ?? "")") { [language, request] in
            await model.load(document, language: language, request: request)
        }
    }
}

@available(iOS 18.0, *)
private struct LyricTranslationView: View {
    let document: LyricsDocument
    let hasTranslation: Bool
    let apply: (LyricTranslation?) -> Void
    @AppStorage("lyricTranslationSource") private var source = "auto"
    @AppStorage("lyricTranslationTarget") private var target = "es"
    @State private var languages: [Locale.Language] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var requested = false
    @State private var busy = false
    @State private var issue: String?
    @State private var progress = 0.0
    var body: some View {
        List {
            Section {
                Picker("Idioma original", selection: $source) {
                    Text("Detectar automáticamente").tag("auto")
                    languageOptions
                }.disabled(busy)
                Picker("Traducir a", selection: $target) { languageOptions }.disabled(busy)
                if busy {
                    ProgressView("Traduciendo letra…", value: progress)
                    Button("Cancelar") { configuration = nil; requested = false; busy = false }
                } else {
                    Button("Traducir y mostrar", systemImage: "character.bubble") { requested = true }
                        .disabled(languages.isEmpty || source == target).accessibilityIdentifier("translateLyrics")
                    if hasTranslation { Button("Ocultar traducción") { apply(nil) } }
                }
                if source == target { Text("Elige dos idiomas diferentes.").font(.footnote) }
                if let issue { Text(issue).foregroundStyle(.red) }
            } footer: {
                Text("La traducción aparece debajo de cada frase y conserva su sincronización. Apple puede pedir descargar los idiomas; después podrás traducir sin conexión. El texto original no se modifica.")
            }
        }.compactContentSpacing()
        .task {
            languages = await LanguageAvailability().supportedLanguages.sorted { name($0) < name($1) }
        }
        .task(id: requested) {
            guard requested else { return }
            busy = true; issue = nil; progress = 0
            do {
                let key = LyricUnderstanding.translationKey(document, source: source, target: target)
                if let cached = try await MusicToolsCache.shared.read(LyricTranslation.self, key: key) {
                    let value = try LyricTranslation(lines: cached.lines, document: document)
                    try Task.checkCancellation(); busy = false; requested = false; apply(value); return
                }
                guard !document.lines.isEmpty, document.lines.count <= 2000, document.lines.reduce(0, { $0 + $1.text.utf8.count }) <= 100000 else {
                    throw MusicTextError.invalid("Esta letra está vacía o supera el límite de traducción (2000 frases o 100 KB).")
                }
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status
                if source == "auto" { status = try await availability.status(for: document.lines.map(\.text).joined(separator: "\n"), to: Locale.Language(identifier: target)) }
                else { status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) }
                try Task.checkCancellation()
                guard status != .unsupported else { throw MusicTextError.invalid("Apple no admite esta combinación de idiomas. Elige manualmente el idioma original y otro idioma de destino.") }
                let next = TranslationSession.Configuration(source: source == "auto" ? nil : Locale.Language(identifier: source), target: Locale.Language(identifier: target))
                if configuration == next { configuration?.invalidate() } else { configuration = next }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription; busy = false; requested = false } }
        }
        .translationTask(configuration) { session in
            let key = LyricUnderstanding.translationKey(document, source: source, target: target)
            do {
                // The batch call detects the source and requests any downloads.
                // prepareTranslation() fails when automatic detection uses nil.
                let lines = document.lines.filter { !$0.text.isEmpty }
                var translated: [Int: String] = [:]
                for start in stride(from: 0, to: lines.count, by: 40) {
                    try Task.checkCancellation()
                    let group = Array(lines[start..<min(start + 40, lines.count)])
                    let responses = try await translateLines(group, using: session)
                    for response in responses {
                        guard let id = response.clientIdentifier.flatMap(Int.init), translated[id] == nil,
                              group.contains(where: { $0.id == id && $0.text == response.sourceText }) else {
                            throw MusicTextError.invalid("No se pudo asociar la traducción con sus frases originales.")
                        }
                        translated[id] = response.targetText
                    }
                    progress = Double(translated.count) / Double(max(1, lines.count))
                }
                let value = try LyricTranslation(lines: translated, document: document)
                try Task.checkCancellation()
                try await MusicToolsCache.shared.write(value, key: key)
                guard requested, !Task.isCancelled else { return }
                busy = false; requested = false; apply(value)
            } catch is CancellationError { }
            catch { if !Task.isCancelled, requested { issue = error.localizedDescription; busy = false; requested = false } }
        }
    }
    private func name(_ language: Locale.Language) -> String {
        Locale(identifier: "es").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
    @ViewBuilder private var languageOptions: some View {
        ForEach(languages, id: \.minimalIdentifier) { language in Text(name(language)).tag(language.minimalIdentifier) }
    }
}

@available(iOS 18.0, *)
private nonisolated func translateLines(_ lines: [LyricsDocument.Line], using session: TranslationSession) async throws -> [TranslationSession.Response] {
    let requests = lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
    return try await session.translations(from: requests)
}
