import SonoraCore
import SwiftUI

struct MetadataRestoreView: View {
    let controller: MetadataArchiveController
    let track: AudioTrack
    let folder: ScopedFolder
    let snapshot: MetadataSnapshot
    let current: [MetadataField:String]
    let hasArtwork: Bool
    let apply: ([MetadataField:String],ArtworkEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var audioID: String?
    @State private var copies: [MetadataRecordSummary] = []
    @State private var server: URL?
    @State private var client: MetadataArchiveClient?
    @State private var nextCursor: Int64?
    @State private var loading = false
    @State private var issue: String?
    @State private var revision = 0
    @State private var pageTask: Task<Void,Never>?
    private struct Run: Equatable { let offline: Bool; let connection: Int; let revision: Int }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Las copias coinciden con el audio completo. Revisa el álbum y la edición antes de recuperar la información.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loading { ProgressView(audioID == nil ? "Identificando el audio…" : "Buscando copias…") }
                if let issue { Section { Text(issue).foregroundStyle(.secondary); Button("Reintentar") { revision += 1 } } }
                if controller.settings.effectiveOffline { Label("Copias de este iPhone · Sin conexión",systemImage:"wifi.slash").font(.footnote) }
                Section("Copias confirmadas") {
                    ForEach(copies) { copy in
                        if let audioID {
                            NavigationLink {
                                MetadataRestorePreview(controller:controller,id:copy.id,audioID:audioID,server:server,client:client,
                                    current:current,hasArtwork:hasArtwork) { changes, artwork in
                                    apply(changes,artwork); dismiss()
                                }
                            } label: {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(copy.title.isEmpty ? "Sin título" : copy.title).font(.headline)
                                    Text([copy.artist,copy.album].filter { !$0.isEmpty }.joined(separator:" · ")).foregroundStyle(.secondary)
                                    Text(copy.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("metadata-copy:" + copy.id.uuidString)
                        }
                    }
                    if !loading && copies.isEmpty { Text("No hay copias guardadas para este audio.").foregroundStyle(.secondary) }
                    if nextCursor != nil {
                        Button("Cargar más copias") { pageTask = Task { await loadPage() } }.disabled(loading)
                    }
                }
            }
            .navigationTitle("Recuperar información").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cerrar") { dismiss() } } }
            .task(id:Run(offline:controller.settings.effectiveOffline,connection:controller.settings.configurationRevision,revision:revision)) {
                pageTask?.cancel(); copies = []; nextCursor = nil; client = nil; issue = nil; loading = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    let key = try await AudioContentIdentity.read(track:track,folder:folder,expected:snapshot.fingerprint)
                    try Task.checkCancellation(); audioID = key; server = controller.destination
                    let records = try await controller.store.summaries(audioID:key,server:server)
                    try Task.checkCancellation()
                    merge(records)
                    if !controller.settings.effectiveOffline && server != nil {
                        let connection = try controller.client()
                        let page = try await connection.list(audioID:key)
                        try Task.checkCancellation(); client = connection; nextCursor = page.nextCursor; merge(page.records)
                    }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { issue = error.localizedDescription } }
            }
            .onDisappear { pageTask?.cancel() }
        }
    }
    private func merge(_ records: [MetadataRecordSummary]) {
        var known = Set(copies.map(\.id))
        copies.append(contentsOf:records.filter { known.insert($0.id).inserted })
        copies.sort { $0.confirmedAt > $1.confirmedAt || ($0.confirmedAt == $1.confirmedAt && $0.id.uuidString < $1.id.uuidString) }
    }
    private func loadPage() async {
        guard let client, let audioID, let cursor = nextCursor else { return }
        loading = true; issue = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let page = try await client.list(audioID:audioID,before:cursor)
            try Task.checkCancellation(); nextCursor = page.nextCursor; merge(page.records)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
}

private struct MetadataRestorePreview: View {
    let controller: MetadataArchiveController
    let id: UUID
    let audioID: String
    let server: URL?
    let client: MetadataArchiveClient?
    let current: [MetadataField:String]
    let hasArtwork: Bool
    let apply: ([MetadataField:String],ArtworkEdit) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var record: ConfirmedMetadataRecord?
    @State private var image: UIImage?
    @State private var selected: Set<MetadataField> = []
    @State private var onlyMissing = true
    @State private var includeArtwork = false
    @State private var issue: String?
    private var available: [MetadataField:String] { record?.metadata ?? [:] }
    private var differences: [MetadataField:String] {
        available.filter { field, text in text != (current[field] ?? "") && (!onlyMissing || (current[field] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
    }
    private var changes: [MetadataField:String] { differences.filter { selected.contains($0.key) } }
    private var artwork: ArtworkEdit { includeArtwork ? (record?.artwork.map(ArtworkEdit.replace) ?? .remove) : .keep }
    var body: some View {
        Form {
            if let record {
                Section {
                    Text("Copia confirmada el \(record.date.formatted(date:.abbreviated,time:.shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Solo completar campos vacíos",isOn:$onlyMissing).accessibilityIdentifier("archiveOnlyMissing")
                } footer: {
                    Text("Aplicar cambia el borrador. Guarda en Información para actualizar el archivo.")
                }
                Section("Revisa los cambios") {
                    ForEach(MetadataField.allCases.filter { available[$0] != nil }) { field in
                        Toggle(isOn:Binding(get:{ selected.contains(field) },set:{ if $0 { selected.insert(field) } else { selected.remove(field) } })) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(field.title).font(.headline)
                                Text("Actual: \(display(current[field] ?? ""))").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                Text("Copia: \(display(available[field] ?? ""))").font(.subheadline).lineLimit(field == .lyrics ? 8 : 3)
                                if field == .lyrics, let attribution = LyricsDocument(text:available[field] ?? "").attribution { Text(attribution).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(differences[field] == nil).accessibilityIdentifier("archive-field-" + field.rawValue)
                    }
                }
                if record.artwork != nil || hasArtwork {
                    Section("Carátula") {
                        if let image { Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:180).frame(maxWidth:.infinity).accessibilityLabel("Carátula guardada") }
                        Toggle(record.artwork == nil ? "Quitar carátula actual" : "Usar carátula guardada",isOn:$includeArtwork).disabled(onlyMissing && hasArtwork)
                    }
                }
            } else if let issue { Text(issue).foregroundStyle(.secondary) }
            else { ProgressView("Leyendo copia…") }
        }
        .navigationTitle("Revisar copia").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) {
            if record != nil {
                Button("Aplicar al editor") { apply(changes,artwork) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(changes.isEmpty && artwork == .keep ? Color.secondary : (scheme == .dark ? Color.black : Color.white))
                    .frame(maxWidth:.infinity).disabled(changes.isEmpty && artwork == .keep)
                    .accessibilityIdentifier("applyArchivedMetadata")
                    .padding().frame(maxWidth:.infinity).background(.bar)
            }
        }
        .onChange(of:onlyMissing) { resetSelection() }
        .task(id:controller.settings.effectiveOffline) {
            record = nil; issue = nil; image = nil
            do {
                let copy: ConfirmedMetadataRecord
                if let saved = try await controller.store.record(id,audioID:audioID,server:server) { copy = saved }
                else {
                    guard !controller.settings.effectiveOffline, let client, let server else { throw MetadataArchiveError.notCached }
                    copy = try await client.record(id,audioID:audioID)
                    try await controller.store.cache(copy,server:server)
                }
                var preview: Data?
                if let cover = copy.artwork { preview = try await Task.detached { try ArtworkCodec.prepare(cover) }.value }
                try Task.checkCancellation(); image = preview.flatMap(UIImage.init(data:)); record = copy; resetSelection()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
    private func display(_ text: String) -> String { text.isEmpty ? "Vacío" : String(text.prefix(4096)) }
    private func resetSelection() {
        selected = Set(differences.keys)
        includeArtwork = record?.artwork != nil && (!onlyMissing || !hasArtwork)
    }
}
