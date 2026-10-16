import SonoraCore
import SwiftUI

struct MetadataProposalView: View {
    let recording: MetadataRecording
    let edition: MetadataReleaseChoice?
    let current: [MetadataField: String]
    let hasArtwork: Bool
    let duration: Double
    let apply: ([MetadataField: String], Data?) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var settings = MetadataAssistantSettings.shared
    @State private var proposal: MetadataProposal?
    @State private var image: UIImage?
    @State private var onlyMissing = true
    @State private var selected: Set<MetadataField> = []
    @State private var includeArtwork = false
    @State private var syncedLyrics = true
    @State private var loading = false
    @State private var issue: String?
    @State private var revision = 0
    private struct Run: Equatable { let offline: Bool; let revision: Int; let connectionRevision: Int }
    private var values: [MetadataField: String] {
        var values = proposal?.values ?? [:]
        if let lyrics = proposal?.lyrics {
            values[.lyrics] = syncedLyrics ? lyrics.syncedLyrics : lyrics.plainLyrics
        }
        return values
    }
    private var changes: [MetadataField: String] {
        MetadataSuggestions.changes(proposed: values, current: current, onlyMissing: onlyMissing).filter { selected.contains($0.key) }
    }
    private var cannotApply: Bool { loading || (changes.isEmpty && !includeArtwork) }

    var body: some View {
        Form {
            Section {
                RecordingSummary(recording: recording)
                if let edition { Text(edition.title).foregroundStyle(.secondary) }
            }
            if loading { Section { ProgressView("Preparando propuestas…") } }
            if let issue {
                Section {
                    Text(issue).foregroundStyle(.secondary)
                    Button("Reintentar") { revision += 1 }
                }
            }
            if let proposal {
                if let date = proposal.savedAt { Section { CachedMetadataLabel(date: date) } }
                if settings.effectiveOffline {
                    Section { Label("Modo desconectado", systemImage: "wifi.slash").font(.footnote) }
                }
                Section {
                    Toggle("Solo completar campos vacíos", isOn: $onlyMissing)
                        .accessibilityIdentifier("metadataOnlyMissing")
                    Text("Desactívalo para elegir qué información existente quieres sustituir.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Revisa los cambios") {
                    ForEach(MetadataField.allCases.filter { $0 != .lyrics && values[$0] != nil }) { field in
                        fieldToggle(field)
                    }
                }
                if let lyrics = proposal.lyrics {
                    Section("Letra de LRCLIB") {
                        if !(lyrics.syncedLyrics ?? "").isEmpty && !(lyrics.plainLyrics ?? "").isEmpty {
                            Picker("Tipo de letra", selection: $syncedLyrics) {
                                Text("Sincronizada").tag(true)
                                Text("Texto").tag(false)
                            }.pickerStyle(.segmented)
                        }
                        fieldToggle(.lyrics)
                    }
                }
                if let image {
                    Section("Carátula de esta edición") {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).frame(maxWidth: .infinity)
                            .accessibilityLabel("Carátula propuesta")
                        Toggle("Usar esta carátula", isOn: $includeArtwork).disabled(onlyMissing && hasArtwork)
                        if hasArtwork { Text("El archivo ya tiene una carátula.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if !proposal.notices.isEmpty {
                    Section("Disponibilidad") {
                        ForEach(proposal.notices.indices, id: \.self) { index in Text(proposal.notices[index]).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Text("Aplicar lleva los cambios al editor. El archivo se actualiza cuando pulses Guardar en la pantalla Información.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Grabación en MusicBrainz", destination: URL(string: "https://musicbrainz.org/recording/\(recording.id)")!)
                    if let edition {
                        Link("Edición en MusicBrainz y Cover Art Archive", destination: URL(string: "https://musicbrainz.org/release/\(edition.id)")!)
                    }
                    if proposal.lyrics != nil { Link("Letras: LRCLIB", destination: URL(string: "https://lrclib.net")!) }
                }
            }
        }
        .navigationTitle("Revisar información").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if proposal != nil {
                Button("Aplicar al editor") { applySelection() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(cannotApply ? Color.secondary : (scheme == .dark ? Color.black : Color.white))
                    .frame(maxWidth: .infinity).disabled(cannotApply)
                    .accessibilityIdentifier("applyMetadataSuggestions")
                    .padding().frame(maxWidth: .infinity).background(.bar)
            }
        }
        .onChange(of: onlyMissing) { resetSelection() }
        .task(id: Run(offline: settings.effectiveOffline, revision: revision, connectionRevision: settings.configurationRevision)) {
            loading = true; issue = nil; proposal = nil; image = nil
            defer { if !Task.isCancelled { loading = false } }
            do {
                let result = try await MetadataProposalLoader.load(recording: recording, edition: edition, duration: duration,
                    client: settings.client(), offline: settings.effectiveOffline)
                try Task.checkCancellation()
                proposal = result; image = result.artwork.flatMap(UIImage.init(data:))
                syncedLyrics = !(result.lyrics?.syncedLyrics ?? "").isEmpty
                resetSelection()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }

    private func fieldToggle(_ field: MetadataField) -> some View {
        let previous = current[field] ?? "", proposed = values[field] ?? ""
        return Toggle(isOn: Binding(get: { selected.contains(field) }, set: { include in
            if include { selected.insert(field) } else { selected.remove(field) }
        })) {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.title).font(.headline)
                Text("Actual: \(previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Vacío" : previous)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(field == .lyrics ? 4 : 3)
                Text("Propuesta: \(proposed)").font(.subheadline).lineLimit(field == .lyrics ? 8 : nil)
                if previous == proposed { Text("Coincide con la información actual").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
        .disabled(previous == proposed || (onlyMissing && !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityIdentifier("suggestion-\(field.rawValue)")
    }
    private func resetSelection() {
        selected = Set(MetadataSuggestions.changes(proposed: values, current: current, onlyMissing: onlyMissing).keys)
        includeArtwork = proposal?.artwork != nil && (!onlyMissing || !hasArtwork)
    }
    private func applySelection() {
        do {
            let artwork = includeArtwork ? proposal?.artwork : nil
            try MetadataPatch(values: changes, artwork: artwork.map(ArtworkEdit.replace) ?? .keep).validate()
            apply(changes, artwork)
        } catch { issue = error.localizedDescription }
    }
}
