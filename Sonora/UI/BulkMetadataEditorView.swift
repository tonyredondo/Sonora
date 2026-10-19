import PhotosUI
import SonoraCore
import SwiftUI

enum BulkMetadataContext {
    case selection, artist(String), album(String)
    var title: String {
        switch self { case .selection: "Editar canciones"; case .artist: "Editar artista"; case .album: "Editar álbum" }
    }
    var name: String? {
        switch self { case .selection: nil; case .artist(let name), .album(let name): name }
    }
    var fields: [MetadataField] {
        let first: [MetadataField]
        switch self {
        case .selection: first = [.artist, .album, .albumArtist, .genre, .date]
        case .artist: first = [.artist, .albumArtist, .genre]
        case .album: first = [.album, .albumArtist, .artist, .date, .genre]
        }
        return first + MetadataField.allCases.filter { !first.contains($0) }
    }
}

struct BulkMetadataEditorView: View {
    let player: PlaybackController
    let tracks: [AudioTrack]
    var context: BulkMetadataContext = .selection
    @State private var originals: [MetadataField: Set<String>] = [:]
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
    @State private var confirmDiscard = false
    private var changed: Bool { result == nil && (!enabled.isEmpty || artwork != .keep) }
    @State private var photo: PhotosPickerItem?
    @State private var importingArtwork = false
    @State private var artwork: ArtworkEdit = .keep
    @State private var result: MetadataBatchResult?
    private var patch: MetadataPatch { MetadataPatch(values: Dictionary(uniqueKeysWithValues: enabled.map { ($0, values[$0] ?? "") }), artwork: artwork) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = context.name { Text(name).font(.headline) }
                    Text(songCount(tracks.count))
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
                    ForEach(context.fields) { field in
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
                            } else {
                                Text(mixed.contains(field) ? "Varios valores · se conservarán" : (values[field].flatMap { $0.isEmpty ? nil : $0 } ?? "Sin información"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }.disabled(saving || result != nil)
                    }
                    Section {
                        if importingArtwork { ProgressView("Preparando carátula") }
                        CompactActionHeader {
                            HStack(spacing: 12) {
                                if case .replace(let data) = artwork, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64) }
                                Text("Carátula común").font(.headline)
                            }
                        } actions: {
                            CompactActionRow(layout: artwork == .keep ? .inline : .icons) {
                                PhotosPicker(selection: $photo, matching: .images) {
                                    CompactActionLabel(title: "Elegir carátula para todas", icon: "photo", caption: "Elegir")
                                }
                                Button(role: .destructive) { artwork = .remove } label: {
                                    CompactActionLabel(title: "Quitar carátulas de todas", icon: "trash", caption: "Quitar", destructive: true)
                                }
                                if artwork != .keep {
                                    Button { artwork = .keep } label: {
                                        CompactActionLabel(title: "Conservar las carátulas actuales", icon: "arrow.uturn.backward", caption: "Conservar")
                                    }
                                }
                            }
                        }
                    }.compactActionListRow().disabled(saving || importingArtwork || result != nil)
                }
                if !blocked.isEmpty { Section("Sin permiso de escritura") { ForEach(blocked, id: \.self) { Text($0) }; Text("Selecciona únicamente los archivos compatibles para editarlos.").font(.footnote) } }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .compactContentSpacing()
            .navigationTitle(context.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancelar" : "Listo") { if changed { confirmDiscard = true } else { dismiss() } }.disabled(saving || importingArtwork) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { confirm = true }.disabled(tracks.isEmpty || expected.count != tracks.count || !loaded || !blocked.isEmpty || saving || importingArtwork || result != nil || (enabled.isEmpty && artwork == .keep))
                }
            }
            .sheet(isPresented: $confirm) {
                NavigationStack {
                    Form {
                        Section {
                            if let name = context.name { Text(name).font(.headline) }
                            Text(songCount(tracks.count))
                            Text("Solo se aplicarán estos cambios. El resto de la información se conservará.").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(context.fields.filter { enabled.contains($0) }) { field in
                            Section(field.title) {
                                let old = originals[field, default: []].sorted()
                                if old.count <= 1 { Text("Actual: \(old.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Sin información")") }
                                else {
                                    DisclosureGroup("Actual: \(old.count) valores diferentes") {
                                        ForEach(old, id: \.self) { Text($0.isEmpty ? "Sin información" : $0) }
                                    }
                                }
                                if let value = values[field], !value.isEmpty { Text("Nuevo: \(value)").fontWeight(.semibold) }
                                else { Label("Se borrará esta etiqueta", systemImage: "trash").foregroundStyle(.red) }
                            }
                        }
                        if artwork != .keep {
                            Section("Carátula") { Text(artwork == .remove ? "Se quitarán las carátulas de todas las canciones." : "Se sustituirán las carátulas de todas las canciones.") }
                        }
                        Button("Guardar en todos los archivos") { save() }.accessibilityIdentifier("confirmBulkSave")
                    }
                    .navigationTitle("Revisar cambios").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Volver") { confirm = false } } }
                }
            }
            .alert("Hay cambios sin guardar", isPresented: $confirmDiscard) {
                Button("Descartar cambios", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) { }
            }
            .task {
                guard !loaded else { return }
                do {
                    for (index, track) in tracks.enumerated() {
                        let snapshot = try await player.readMetadata(for: track)
                        try Task.checkCancellation()
                        for field in MetadataField.allCases { originals[field, default: []].insert(snapshot.values[field] ?? "") }
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
            .interactiveDismissDisabled(saving || importingArtwork || changed)
        }
    }
    private func save() {
        confirm = false
        saving = true; issue = nil
        let changes = patch
        Task {
            defer { saving = false }
            do {
                try changes.validate()
                result = await player.saveMetadataBatch(tracks, expected: expected, patch: changes) { progress = $0 }
            } catch { issue = error.localizedDescription }
        }
    }

}
