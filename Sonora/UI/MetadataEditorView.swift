import ImageIO
import PhotosUI
import SonoraCore
import SwiftUI
import UniformTypeIdentifiers

struct MetadataEditorView: View {
    let player: PlaybackController
    let track: AudioTrack
    var synchronizeLyricsOnOpen = false
    var lyricsOnly = false
    @State private var loadedLyrics = ""
    @State private var lyricsEdited = false
    @State private var confirmDiscard = false
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
    private struct RestoreRequest: Identifiable { let id = UUID(); let folder: ScopedFolder }
    @State private var restoreRequest: RestoreRequest?
    @State private var showLyricsSynchronization = false
    private struct PhraseRequest: Identifiable { let id = UUID(); let draft: LyricsDraft; let line: LyricsDraft.Line }
    @State private var phraseRequest: PhraseRequest?
    private struct PreviewRequest: Identifiable { let id = UUID(); let draft: LyricsDraft }
    @State private var previewRequest: PreviewRequest?
    @State private var sidecarLyrics = ""
    @State private var issue: String?
    @State private var saveIssue: String?

    private var patch: MetadataPatch {
        if lyricsOnly {
            let text = values[.lyrics] ?? ""
            return MetadataPatch(values: text == loadedLyrics ? [:] : [.lyrics: text])
        }
        return MetadataPatch(values: values.filter { $0.key == .lyrics ? lyricsEdited && $0.value != loadedLyrics : snapshot?.values[$0.key] != $0.value }, artwork: artwork)
    }
    private var changed: Bool { !patch.values.isEmpty || artwork != .keep }
    private var existingLyrics: String {
        let draft = values[.lyrics] ?? ""
        return !lyricsEdited && draft.isEmpty && draft == (snapshot?.values[.lyrics] ?? "") ? sidecarLyrics : draft
    }
    private func binding(_ field: MetadataField) -> Binding<String> {
        Binding(get: { field == .lyrics ? existingLyrics : values[field] ?? "" }, set: {
            if field == .lyrics { lyricsEdited = true }
            values[field] = $0
        })
    }
    private var cover: Data? {
        switch artwork { case .keep: snapshot?.artwork; case .replace(let data): data; case .remove: nil }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let snapshot {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lyricsOnly ? values[.title].flatMap { $0.isEmpty ? nil : $0 } ?? track.displayName : track.filename).font(.headline)
                            if !lyricsOnly { Text(snapshot.fileDescription).font(.subheadline).foregroundStyle(.secondary) }
                            if track.cue != nil { Label("Esta pista comparte el audio con otros temas. La información se lee del CUE; la edición del archivo compartido está desactivada.", systemImage: "lock") }
                            else if !snapshot.canWrite { Label("Este archivo es de solo lectura o su formato no admite edición.", systemImage: "lock") }
                            if !lyricsOnly {
                                CompactActionRow(layout: .inline) {
                                    Button { showAssistant = true } label: {
                                        CompactActionLabel(title: "Completar información", icon: "magnifyingglass", caption: "Completar")
                                    }.accessibilityIdentifier("completeMetadata")
                                    if player.metadataArchive != nil {
                                        Button {
                                            do { restoreRequest = RestoreRequest(folder:try player.folderAccess(for:track)) }
                                            catch { issue = error.localizedDescription }
                                        } label: {
                                            CompactActionLabel(title: "Recuperar información guardada", icon: "clock.arrow.circlepath", caption: "Recuperar")
                                        }.accessibilityIdentifier("restoreMetadata")
                                    }
                                }.disabled(!snapshot.canWrite || saving || importing)
                            }
                        }
                    }
                    if !lyricsOnly {
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
                    Section {
                        CompactActionHeader {
                            HStack(spacing: 12) {
                                if let image = coverPreview {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
                                }
                                Text("Carátula").font(.headline)
                            }
                        } actions: {
                            CompactActionRow(layout: .inline) {
                                PhotosPicker(selection: $photo, matching: .images) {
                                    CompactActionLabel(title: "Elegir carátula", icon: "photo", caption: cover == nil ? "Elegir imagen" : "Cambiar")
                                }
                                if cover != nil {
                                    Button(role: .destructive) { artwork = .remove; coverPreview = nil } label: {
                                        CompactActionLabel(title: "Quitar carátulas", icon: "trash", caption: "Quitar", destructive: true)
                                    }
                                }
                            }
                        }
                    }.compactActionListRow().disabled(!snapshot.canWrite || saving || importing)
                    }
                    Section("Letra") {
                        Button(LyricsDocument(text: existingLyrics).lines.isEmpty ? "Buscar o transcribir letra" : "Sincronizar letra", systemImage: "waveform") { showLyricsSynchronization = true }
                            .accessibilityIdentifier("openLyricsSynchronization")
                        if !lyricsOnly {
                            NavigationLink("Editar letra") {
                                Form { lyricsTextEditor }.navigationTitle("Editar letra")
                                    .safeAreaInset(edge: .bottom) { LyricsEditingTransport(player: player, track: track, duration: snapshot.duration, preview: { previewRequest = PreviewRequest(draft: LyricsDraft(text: existingLyrics)) }) }
                            }
                                .accessibilityIdentifier("editLyrics")
                        }
                    }.disabled(!snapshot.canWrite || saving || importing)
                    if lyricsOnly { lyricsTextEditor.disabled(!snapshot.canWrite || saving || importing) }
                    if changed { Label("Cambios sin guardar", systemImage: "pencil.circle").font(.subheadline).accessibilityIdentifier("unsavedMetadata") }
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
            .compactContentSpacing()
            .safeAreaInset(edge: .bottom) {
                if lyricsOnly, let snapshot { LyricsEditingTransport(player: player, track: track, duration: snapshot.duration, preview: { previewRequest = PreviewRequest(draft: LyricsDraft(text: existingLyrics)) }).disabled(saving) }
            }
            .navigationTitle(lyricsOnly ? "Editar texto" : "Información").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { if changed { confirmDiscard = true } else { dismiss() } }.disabled(saving || importing) }
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
            .alert("No se pudo guardar", isPresented: Binding(get: { saveIssue != nil }, set: { if !$0 { saveIssue = nil } })) {
                Button("Volver al borrador", role: .cancel) { saveIssue = nil }
            } message: { Text(saveIssue ?? "") }
            .alert("Hay cambios sin guardar", isPresented: $confirmDiscard) {
                Button("Descartar cambios", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) { }
            }
            .fileImporter(isPresented: $importLyrics, allowedContentTypes: [.plainText, .data]) { result in
                Task {
                    importing = true; defer { importing = false }
                    do { values[.lyrics] = try await LyricsSource.importText(result.get()); lyricsEdited = true }
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
                    var effectiveLyrics = value.values[.lyrics] ?? ""
                    if lyricsOnly || effectiveLyrics.isEmpty {
                        effectiveLyrics = try await LyricsAudioPreparation.existingText(track: track, folder: player.folderAccess(for: track), embedded: effectiveLyrics, expected: value.fingerprint)
                    }
                    var preview: UIImage?
                    if !lyricsOnly, let data = value.artwork,
                       let prepared = try? await Task.detached(operation: { try ArtworkCodec.prepare(data) }).value {
                        preview = UIImage(data: prepared)
                    }
                    try Task.checkCancellation()
                    // Publish the draft only after every read completes, so a late sidecar
                    // or artwork result cannot overwrite edits already entered by the user.
                    sidecarLyrics = effectiveLyrics; loadedLyrics = effectiveLyrics
                    values = value.values
                    if lyricsOnly { values[.lyrics] = effectiveLyrics }
                    coverPreview = preview; snapshot = value; loadedTrackID = track.id
                    if synchronizeLyricsOnOpen && value.canWrite { showLyricsSynchronization = true }
                }
                catch is CancellationError { }
                catch { issue = error.localizedDescription }
            }
            .interactiveDismissDisabled(saving || importing || changed)
            .sheet(item: $previewRequest) { request in
                LyricsDraftPreview(player: player, track: track, draft: request.draft, duration: snapshot?.duration ?? 0)
            }
            .sheet(item: $phraseRequest) { request in
                LyricsPhraseEditor(player: player, track: track, duration: snapshot?.duration ?? 0, draft: request.draft, line: request.line) {
                    values[.lyrics] = $0; lyricsEdited = true
                }
            }
            .sheet(isPresented: $showLyricsSynchronization) {
                if let snapshot {
                    LyricsSynchronizationView(player: player, track: track, current: values, snapshot: snapshot, lyrics: existingLyrics) { values[.lyrics] = $0; lyricsEdited = true }
                }
            }
            .sheet(isPresented: $showAssistant) {
                MetadataLookupView(player: player, track: track, current: values, hasArtwork: cover != nil,
                    duration: snapshot?.duration ?? 0) { changes, image in
                    if changes[.lyrics] != nil { lyricsEdited = true }
                    values.merge(changes) { _, proposed in proposed }
                    if let image { artwork = .replace(image); coverPreview = UIImage(data: image) }
                }
            }
            .sheet(item:$restoreRequest) { request in
                if let snapshot, let controller = player.metadataArchive {
                    MetadataRestoreView(controller:controller,track:track,folder:request.folder,snapshot:snapshot,current:values,hasArtwork:cover != nil) { changes, image in
                        if changes[.lyrics] != nil { lyricsEdited = true }
                        values.merge(changes) { _, proposed in proposed }
                        if image != .keep {
                            artwork = image
                            if case .replace(let data) = image { coverPreview = UIImage(data:data) }
                            else { coverPreview = nil }
                        }
                    }
                }
            }
        }
    }
    private var lyricsTextEditor: some View {
        Group {
            LyricsDraftEditor(player: player, track: track, duration: snapshot?.duration ?? 0, text: binding(.lyrics)) { draft, line in
                phraseRequest = PhraseRequest(draft: draft, line: line)
            }
            Section { Button("Importar .lrc o .txt") { importLyrics = true } }
        }
    }
    private func save() {
        guard let snapshot else { return }
        let change = patch
        Task {
            saving = true; issue = nil; defer { saving = false }
            do {
                try change.validate()
                if let lyrics = change.values[.lyrics] { try LyricsDraft(text: lyrics).validateForPlayback() }
                try await player.saveMetadata(for: track, expected: snapshot.fingerprint, patch: change)
                dismiss()
            } catch { issue = error.localizedDescription; saveIssue = error.localizedDescription }
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
