import SonoraCore
import SwiftUI
// iOS 18 Translation sessions lack Sendable annotations. A session belongs to one
// translationTask, is used sequentially and is never shared with another task.
@preconcurrency import Translation

struct LyricUnderstandingView: View {
    let document: LyricsDocument
    let translation: LyricTranslation?
    let translations: LyricTranslationStore
    let interpretations: LyricInterpretationStore
    let applyTranslation: (LyricTranslation?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    init(document: LyricsDocument, translation: LyricTranslation?, translations: LyricTranslationStore, interpretations: LyricInterpretationStore,
         initialMode: Int = 0, applyTranslation: @escaping (LyricTranslation?) -> Void) {
        self.document = document; self.translation = translation; self.translations = translations
        self.interpretations = interpretations
        self.applyTranslation = applyTranslation; _mode = State(initialValue: initialMode)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Herramienta de letra", selection: $mode) {
                    Text("Significado").tag(0)
                    Text("Traducción").tag(1)
                }.pickerStyle(.segmented).padding()
                if mode == 0 { LyricInterpretationView(document: document, store: interpretations) }
                else if #available(iOS 26.4, *) {
                    ContextualTranslationView(document: document, store: translations, hasTranslation: translation != nil) { value in applyTranslation(value); dismiss() }
                } else if #available(iOS 18.0, *) {
                    LyricTranslationView(document: document, hasTranslation: translation != nil) { value in applyTranslation(value); dismiss() }
                } else {
                    ContentUnavailableView("Necesita iOS 18", systemImage: "character.bubble", description: Text("La traducción local está disponible a partir de iOS 18."))
                }
            }.navigationTitle("Comprender letra").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
        }
    }
}

@available(iOS 26.4, *)
private struct ContextualTranslationView: View {
    let document: LyricsDocument
    let store: LyricTranslationStore
    let hasTranslation: Bool
    let apply: (LyricTranslation?) -> Void
    @AppStorage("lyricTranslationSource") private var source = "auto"
    @AppStorage("lyricTranslationTarget") private var target = "es"
    @State private var languages: [Locale.Language] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var request: (source: String, target: String)?
    @State private var issue: String?
    private var key: String { LyricUnderstanding.translationKey(document, source: source, target: target) }
    private var status: LyricTranslationStore.Status? { store.statuses[key] }
    var body: some View {
        List {
            Section {
                Picker("Idioma original", selection: $source) {
                    Text("Detectar automáticamente").tag("auto"); languageOptions
                }.disabled(request != nil)
                Picker("Traducir a", selection: $target) { languageOptions }.disabled(request != nil)
                if let status { Text(status.message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("translationState") }
                if status?.busy == true || request != nil {
                    ProgressView("Traduciendo letra…")
                } else {
                    Button(status == .needsLanguages ? "Descargar idiomas y traducir" : "Traducir y mostrar", systemImage: "character.bubble") {
                        issue = nil
                        if let cached = store.results[key] { apply(cached); return }
                        do {
                            let from = try AppleLyricTranslator.sourceLanguage(document, source: source)
                            guard from.languageCode != Locale.Language(identifier: target).languageCode else { throw LyricTranslationIssue.sameLanguage }
                            request = (source, target)
                            let next = TranslationSession.Configuration(source: from, target: Locale.Language(identifier: target))
                            if configuration == next { configuration?.invalidate() } else { configuration = next }
                        } catch { issue = error.localizedDescription }
                    }.disabled(languages.isEmpty || source == target || status == .sameLanguage).accessibilityIdentifier("translateLyrics")
                    if hasTranslation { Button("Ocultar traducción") { apply(nil) } }
                }
                if let issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("translationIssue") }
            } footer: {
                Text("Preparamos las letras de toda la cola de reproducción y guardamos cada traducción después de analizar el audio. Conservamos las frases y sus tiempos. Si faltan idiomas, descárgalos una vez para continuar automáticamente y sin conexión.")
            }
        }.compactContentSpacing()
        .task { languages = await LanguageAvailability().supportedLanguages.sorted { name($0) < name($1) } }
        .task(id: key) {
            issue = nil
            await store.restore(document, source: source, target: target)
        }
        .translationTask(configuration) { session in
            guard let current = request else { return }
            do {
                // Download approval stays in Apple's UI, only after this button.
                try await session.prepareTranslation()
                // The independent installed-language session survives this sheet.
                let value = try await store.load(document, source: current.source, target: current.target)
                try Task.checkCancellation()
                request = nil; apply(value)
            } catch {
                request = nil
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
    private func name(_ language: Locale.Language) -> String {
        Locale(identifier: "es").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
    @ViewBuilder private var languageOptions: some View {
        ForEach(languages, id: \.minimalIdentifier) { Text(name($0)).tag($0.minimalIdentifier) }
    }
}

private struct LyricInterpretationView: View {
    let document: LyricsDocument
    let store: LyricInterpretationStore
    @AppStorage("lyricMeaningLanguage") private var language = "es"
    private var key: String { store.key(document, language: language) }
    private var status: LyricInterpretationStore.Status? { store.statuses[key] }
    private var explanation: String? { store.results[key]?.explanation }
    var body: some View {
        List {
            Section {
                Picker("Idioma de respuesta", selection: $language) {
                    Text("Español").tag("es"); Text("English").tag("en"); Text("Français").tag("fr")
                    Text("Deutsch").tag("de"); Text("Italiano").tag("it"); Text("Português").tag("pt")
                }.accessibilityIdentifier("interpretationLanguage")
                if status == .interpreting {
                    ProgressView("Interpretando con Codex…")
                        .accessibilityIdentifier("interpretationState")
                } else if explanation == nil {
                    if status == .queued {
                        Text(store.automaticIssue ?? (store.waitingForConnection ? "Pendiente de conexión con el servidor." : "Interpretación en cola…"))
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("interpretationState")
                    }
                    Button(status == .queued ? "Interpretar ahora" : "Interpretar letra", systemImage: "sparkles") {
                        Task { _ = try? await store.load(document, language: language) }
                    }
                        .accessibilityIdentifier("interpretLyrics")
                }
                if case .failed(let issue) = status { Text(issue).foregroundStyle(.red).accessibilityIdentifier("interpretationIssue") }
            } footer: { Text("Preparamos el significado de toda la cola, una canción cada vez. Puedes desactivarlo en Ajustes → Preparación automática. GPT Astra ofrece una lectura posible, no una explicación confirmada por su autor. Cada análisis nuevo envía la letra a Codex desde tu servidor y consume uso de tu plan. Los resultados guardados funcionan sin conexión.") }
            if document.isAITranscribed { Section { Text("Esta letra fue transcrita por IA y puede contener errores que afecten a la interpretación.").font(.footnote) } }
            if let explanation { Section("Interpretación de IA") { Text(explanation).textSelection(.enabled).accessibilityIdentifier("lyricInterpretation") } }
        }
        .compactContentSpacing()
        .task(id: key) { await store.restore(document, language: language) }
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
