import SonoraCore
import SwiftUI
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
                else {
                    CodexTranslationView(document: document, store: translations, hasTranslation: translation != nil) { value in applyTranslation(value); dismiss() }
                }
            }.navigationTitle("Comprender letra").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
        }
    }
}

private struct CodexTranslationView: View {
    let document: LyricsDocument
    let store: LyricTranslationStore
    let hasTranslation: Bool
    let apply: (LyricTranslation?) -> Void
    @AppStorage("lyricTranslationSource") private var source = "auto"
    @AppStorage("lyricTranslationTarget") private var target = "es"
    @State private var requested = false
    @State private var issue: String?
    private var key: String { LyricUnderstanding.translationKey(document, source: source, target: target) }
    private var status: LyricTranslationStore.Status? { store.statuses[key] }
    private var languages: [String] {
        Set(["ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant", source, target])
            .filter { $0 != "auto" }.sorted { name($0) < name($1) }
    }
    var body: some View {
        List {
            Section {
                Picker("Idioma original", selection: $source) {
                    Text("Detectar automáticamente").tag("auto"); languageOptions
                }.disabled(requested).accessibilityIdentifier("translationSourceLanguage")
                Picker("Traducir a", selection: $target) { languageOptions }
                    .disabled(requested).accessibilityIdentifier("translationTargetLanguage")
                if let message = store.message(for: key) {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("translationState")
                }
                if status == .translating || requested { ProgressView("Traduciendo letra…") }
                if !requested {
                    Button(store.results[key] == nil ? "Traducir y mostrar" : "Mostrar traducción", systemImage: "character.bubble") {
                        requested = true; issue = nil
                    }.disabled(source == target || status == .sameLanguage).accessibilityIdentifier("translateLyrics")
                    if hasTranslation { Button("Ocultar traducción") { apply(nil) } }
                }
                if let issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("translationIssue") }
            } footer: {
                Text("Traducimos la letra completa con Codex para conservar el contexto y mostramos cada fragmento junto a su frase y su tiempo original. Preparamos toda la cola con hasta cuatro solicitudes simultáneas entre traducción y significado. Cada traducción nueva usa tu servidor y consume uso de tu plan. Las traducciones guardadas funcionan sin conexión.")
            }
        }.compactContentSpacing()
        .task(id: key) {
            issue = nil
            await store.restore(document, source: source, target: target)
        }
        .task(id: requested) {
            guard requested else { return }
            defer { requested = false }
            do {
                let value = try await store.load(document, source: source, target: target)
                try Task.checkCancellation()
                apply(value)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
    private func name(_ language: String) -> String {
        Locale(identifier: "es").localizedString(forIdentifier: language) ?? language
    }
    @ViewBuilder private var languageOptions: some View {
        ForEach(languages, id: \.self) { Text(name($0)).tag($0) }
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
            } footer: { Text("Preparamos toda la cola con hasta cuatro solicitudes simultáneas entre significado y traducción. Puedes desactivarlo en Ajustes → Preparación automática. GPT Astra ofrece una lectura posible, no una explicación confirmada por su autor. Cada análisis nuevo envía la letra a Codex desde tu servidor y consume uso de tu plan. Los resultados guardados funcionan sin conexión.") }
            if document.isAITranscribed { Section { Text("Esta letra fue transcrita por IA y puede contener errores que afecten a la interpretación.").font(.footnote) } }
            if let explanation { Section("Sobre la canción") { Text(explanation).textSelection(.enabled).accessibilityIdentifier("lyricInterpretation") } }
        }
        .compactContentSpacing()
        .task(id: key) { await store.restore(document, language: language) }
    }
}
