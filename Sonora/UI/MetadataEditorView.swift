import ImageIO
import PhotosUI
import SonoraCore
import SwiftUI
import UniformTypeIdentifiers

struct MetadataEditorView: View {
    let player: PlaybackController
    let track: AudioTrack
    var synchronizeLyricsOnOpen = false
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MetadataSnapshot?
    @State private var loadedTrackID: String?
    @State private var values: [MetadataField: String] = [:]
    @State private var artwork: ArtworkEdit = .keep
    @State private var coverPreview: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var saving = false
    @State private var importing = false
    @State private var importLyrics = false
    @State private var confirm = false
    @State private var showAssistant = false
    @State private var showLyricsSynchronization = false
    @State private var sidecarLyrics = ""
    @State private var issue: String?

    private var patch: MetadataPatch {
        MetadataPatch(values: values.filter { snapshot?.values[$0.key] != $0.value }, artwork: artwork)
    }
    private var changed: Bool { !patch.values.isEmpty || artwork != .keep }
    private func binding(_ field: MetadataField) -> Binding<String> {
        Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
    }
    private var cover: Data? {
        switch artwork { case .keep: snapshot?.artwork; case .replace(let data): data; case .remove: nil }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let snapshot {
                    Section {
                        Text(track.filename).font(.headline)
                        Text(snapshot.fileDescription).foregroundStyle(.secondary)
                        if track.cue != nil { Label("Esta pista comparte el audio con otros temas. La información se lee del CUE; la edición del archivo compartido está desactivada.", systemImage: "lock") }
                        else if !snapshot.canWrite { Label("Este archivo es de solo lectura o su formato no admite edición.", systemImage: "lock") }
                    }
                    Section {
                        Button { showAssistant = true } label: { Label("Completar información", systemImage: "magnifyingglass") }
                            .accessibilityIdentifier("completeMetadata")
                    }.disabled(!snapshot.canWrite || saving || importing)
                    Section("Información") {
                        ForEach(MetadataField.allCases.filter { ![.lyrics, .comment].contains($0) }) { field in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(field.title).font(.caption).foregroundStyle(.secondary)
                                TextField(field.title, text: binding(field), prompt: Text(field.title))
                                    .keyboardType(field.isNumber ? .numberPad : .default)
                                    .accessibilityLabel(field.title).accessibilityIdentifier("metadata-\(field.rawValue)")
                            }
                        }
                        TextField("Comentarios", text: binding(.comment), axis: .vertical).lineLimit(2...5)
                            .accessibilityIdentifier("metadata-comment")
                    }.disabled(!snapshot.canWrite || saving)
                    Section("Carátula") {
                        if let image = coverPreview {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).frame(maxWidth: .infinity)
                        }
                        PhotosPicker(selection: $photo, matching: .images) { Label("Elegir carátula", systemImage: "photo") }
                        if cover != nil { Button("Quitar carátulas", role: .destructive) { artwork = .remove; coverPreview = nil } }
                    }.disabled(!snapshot.canWrite || saving || importing)
                    Section("Letra") {
                        Button("Sincronizar letra", systemImage: "waveform") { showLyricsSynchronization = true }
                            .accessibilityIdentifier("openLyricsSynchronization")
                        NavigationLink("Editar letra") {
                            Form {
                                TextEditor(text: binding(.lyrics)).frame(minHeight: 300).accessibilityIdentifier("metadata-lyrics")
                                Button("Importar .lrc o .txt") { importLyrics = true }
                                Text("Puedes escribir texto o pegar líneas sincronizadas, por ejemplo: [00:12.50]Una canción.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.navigationTitle("Letra")
                        }.accessibilityIdentifier("editLyrics")
                    }.disabled(!snapshot.canWrite || saving || importing)
                    if importing { ProgressView("Importando…") }
                    if saving { ProgressView("Guardando…") }
                    if let issue { Section { Text(issue).foregroundStyle(.red) } }
                    Section {
                        Text("Guardar actualiza las etiquetas del archivo original. Los cambios se comprueban antes de sustituirlo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let issue {
                    ContentUnavailableView("No se pudo abrir la información", systemImage: "exclamationmark.circle", description: Text(issue))
                } else if issue == nil { ProgressView("Leyendo información…") }
            }
            .navigationTitle("Información").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { confirm = true }.disabled(snapshot?.canWrite != true || !changed || saving || importing)
                        .accessibilityIdentifier("metadataSave")
                }
            }
            .confirmationDialog("Guardar en \(track.filename)", isPresented: $confirm, titleVisibility: .visible) {
                Button("Guardar en archivo") { save() }
            } message: {
                Text("Se actualizarán: \(patch.values.keys.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))\(artwork == .keep ? "" : ", carátula").")
            }
            .fileImporter(isPresented: $importLyrics, allowedContentTypes: [.plainText, .data]) { result in
                Task {
                    importing = true; defer { importing = false }
                    do { values[.lyrics] = try await LyricsSource.importText(result.get()) }
                    catch { issue = error.localizedDescription }
                }
            }
            .onChange(of: photo) {
                Task {
                    importing = true; defer { importing = false }
                    do {
                        guard let data = try await photo?.loadTransferable(type: Data.self) else { return }
                        let prepared = try await Task.detached { try ArtworkCodec.prepare(data) }.value
                        artwork = .replace(prepared); coverPreview = UIImage(data: prepared)
                    } catch { issue = error.localizedDescription }
                }
            }
            .task(id: track.id) {
                guard loadedTrackID != track.id else { return }
                do {
                    let value = try await player.readMetadata(for: track)
                    try Task.checkCancellation()
                    snapshot = value; values = value.values; loadedTrackID = track.id
                    if (value.values[.lyrics] ?? "").isEmpty {
                        sidecarLyrics = try await LyricsAudioPreparation.existingText(track: track, folder: player.folderAccess(for: track), embedded: "", expected: value.fingerprint)
                    }
                    if synchronizeLyricsOnOpen && value.canWrite { showLyricsSynchronization = true }
                    if let data = value.artwork, let preview = try? await Task.detached(operation: { try ArtworkCodec.prepare(data) }).value {
                        coverPreview = UIImage(data: preview)
                    }
                }
                catch is CancellationError { }
                catch { issue = error.localizedDescription }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $showLyricsSynchronization) {
                if let snapshot {
                    let draft = values[.lyrics] ?? ""
                    let existing = draft.isEmpty && draft == (snapshot.values[.lyrics] ?? "") ? sidecarLyrics : draft
                    LyricsSynchronizationView(player: player, track: track, current: values, snapshot: snapshot, lyrics: existing) { values[.lyrics] = $0 }
                }
            }
            .sheet(isPresented: $showAssistant) {
                MetadataLookupView(player: player, track: track, current: values, hasArtwork: cover != nil,
                    duration: snapshot?.duration ?? 0) { changes, image in
                    values.merge(changes) { _, proposed in proposed }
                    if let image { artwork = .replace(image); coverPreview = UIImage(data: image) }
                }
            }
        }
    }
    private func save() {
        guard let snapshot else { return }
        let change = patch
        Task {
            saving = true; issue = nil; defer { saving = false }
            do {
                try change.validate()
                try await player.saveMetadata(for: track, expected: snapshot.fingerprint, patch: change)
                dismiss()
            } catch { issue = error.localizedDescription }
        }
    }
}

enum ArtworkCodec {
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 25_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw MetadataIOError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw MetadataIOError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MetadataIOError.invalidImage }
        return output as Data
    }
}
