import PhotosUI
import SonoraCore
import SwiftUI

struct BulkMetadataEditorView: View {
    let player: PlaybackController
    let tracks: [AudioTrack]
    @Environment(\.dismiss) private var dismiss
    @State private var expected: [String: FileFingerprint] = [:]
    @State private var values: [MetadataField: String] = [:]
    @State private var mixed: Set<MetadataField> = []
    @State private var enabled: Set<MetadataField> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var progress = 0
    @State private var issue: String?
    @State private var blocked: [String] = []
    @State private var confirm = false
    @State private var photo: PhotosPickerItem?
    @State private var importingArtwork = false
    @State private var artwork: ArtworkEdit = .keep
    @State private var result: MetadataBatchResult?
    private var patch: MetadataPatch { MetadataPatch(values: Dictionary(uniqueKeysWithValues: enabled.map { ($0, values[$0] ?? "") }), artwork: artwork) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(tracks.count) canciones")
                    Text("Activa solo los campos que quieras aplicar a todas. Un campo activado y vacío borrará esa etiqueta.").font(.footnote).foregroundStyle(.secondary)
                }
                if (!loaded && issue == nil) || saving { ProgressView("\(saving ? "Guardando" : "Leyendo") · \(progress) / \(tracks.count)") }
                if let result {
                    Section("Resultado") {
                        Text("Guardados \(result.written) de \(tracks.count)").accessibilityIdentifier("bulkResult")
                        ForEach(result.failures) { failure in VStack(alignment: .leading) { Text(failure.filename); Text(failure.message).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                if loaded && result == nil {
                    ForEach(MetadataField.allCases) { field in
                        Section {
                            Toggle(field.title, isOn: Binding(get: { enabled.contains(field) }, set: { if $0 { enabled.insert(field) } else { enabled.remove(field) } }))
                                .accessibilityIdentifier("bulk-apply-\(field.rawValue)")
                            if enabled.contains(field) {
                                if field == .lyrics {
                                    TextEditor(text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })).frame(minHeight: 200)
                                } else {
                                    TextField(mixed.contains(field) ? "Varios valores" : field.title, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }))
                                        .keyboardType(field.isNumber ? .numberPad : .default)
                                        .accessibilityIdentifier("bulk-field-\(field.rawValue)")
                                }
                            } else if mixed.contains(field) { Text("Varios valores · se conservarán").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(saving || result != nil)
                    }
                    Section("Carátula común") {
                        if importingArtwork { ProgressView("Preparando carátula") }
                        PhotosPicker(selection: $photo, matching: .images) { Label("Elegir carátula para todas", systemImage: "photo") }
                        if case .replace(let data) = artwork, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160) }
                        Button("Quitar carátulas de todas", role: .destructive) { artwork = .remove }
                        if artwork != .keep { Button("Conservar las carátulas actuales") { artwork = .keep } }
                    }.disabled(saving || importingArtwork || result != nil)
                }
                if !blocked.isEmpty { Section("Sin permiso de escritura") { ForEach(blocked, id: \.self) { Text($0) }; Text("Selecciona únicamente los archivos compatibles para editarlos.").font(.footnote) } }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle("Información").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancelar" : "Listo") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { confirm = true }.disabled(tracks.isEmpty || expected.count != tracks.count || !loaded || !blocked.isEmpty || saving || importingArtwork || result != nil || (enabled.isEmpty && artwork == .keep))
                }
            }
            .confirmationDialog("Guardar en \(tracks.count) archivos", isPresented: $confirm, titleVisibility: .visible) {
                Button("Guardar en todos los archivos") {
                    Task {
                        saving = true; issue = nil; defer { saving = false }
                        do {
                            try patch.validate()
                            result = await player.saveMetadataBatch(tracks, expected: expected, patch: patch) { progress = $0 }
                        } catch { issue = error.localizedDescription }
                    }
                }
            } message: { Text("Se aplicarán únicamente los campos activados. Cada archivo se comprobará antes de sustituirlo.") }
            .task {
                guard !loaded else { return }
                do {
                    for (index, track) in tracks.enumerated() {
                        let snapshot = try await player.readMetadata(for: track)
                        try Task.checkCancellation()
                        expected[track.id] = snapshot.fingerprint
                        if !snapshot.canWrite { blocked.append(player.location(for: track)) }
                        if index == 0 { values = snapshot.values }
                        else {
                            for field in MetadataField.allCases where values[field] != snapshot.values[field] { mixed.insert(field); values[field] = "" }
                        }
                        progress = index + 1
                    }
                    loaded = true
                } catch is CancellationError { }
                catch { issue = error.localizedDescription }
            }
            .onChange(of: photo) {
                Task {
                    importingArtwork = true; defer { importingArtwork = false }
                    do { if let data = try await photo?.loadTransferable(type: Data.self) { artwork = .replace(try await Task.detached { try ArtworkCodec.prepare(data) }.value) } }
                    catch { issue = error.localizedDescription }
                }
            }
            .interactiveDismissDisabled(saving || importingArtwork)
        }
    }
}
