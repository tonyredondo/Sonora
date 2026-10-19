import SwiftUI
import UniformTypeIdentifiers

struct LocalMusicView: View {
    let player: PlaybackController
    @State private var chooseFolder = false
    @State private var deleting: ImportedMusicRecord?
    @State private var removing = false
    @State private var browsingSource: String?
    @State private var showFiles = false
    @Environment(\.scenePhase) private var phase
    private var imports: LocalImportController { player.localImports }
    var body: some View {
        List {
            Section {
                Button("Copiar carpeta a Sonora", systemImage: "square.and.arrow.down") { chooseFolder = true }
                    .disabled(imports.isImporting || removing || player.isDeletingFiles).accessibilityIdentifier("importLocalFolder")
                Text("Guarda una carpeta con su música, carátulas y letras para escucharla sin conexión. El original se conserva.").font(.footnote).foregroundStyle(.secondary)
            }
            if imports.isImporting {
                Section("Importando") {
                    if let value = imports.progress {
                        ProgressView(value: Double(value.completed), total: Double(max(1, value.total)))
                        Text("\(value.completed) de \(value.total) archivos · \(ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file))")
                        Text(value.filename).font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView("Revisando la carpeta…") }
                    Button("Cancelar importación", role: .cancel) { imports.cancel() }
                }
            }
            if let name = imports.completedName { Section { Label("Copia guardada: \(name)", systemImage: "checkmark.circle").accessibilityIdentifier("localImportCompleted") } }
            if let issue = imports.issue { Section { Text(issue); Button("Cerrar aviso") { imports.issue = nil } } }
            Section("Disponibles sin conexión") {
                ForEach(imports.copies) { copy in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(copy.name).font(.headline).accessibilityIdentifier("localCopyName:" + copy.id)
                        Text("\(copy.files) archivos · \(ByteCountFormatter.string(fromByteCount: copy.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        CompactActionRow {
                            Button { player.chooseFolder(imports.musicURL(copy), name: copy.name + " · Local") } label: {
                                CompactActionLabel(title: "Reproducir", icon: "play.fill", prominent: true)
                            }.accessibilityIdentifier("playLocalCopy:" + copy.id)
                            Button {
                                removing = true
                                Task {
                                    defer { removing = false }
                                    do {
                                        if player.library.sourceID(matching: imports.musicURL(copy)) == nil { try await imports.include(copy, library: player.library) }
                                        browsingSource = player.library.sourceID(matching: imports.musicURL(copy)); showFiles = browsingSource != nil
                                    } catch { imports.issue = error.localizedDescription }
                                }
                            } label: { CompactActionLabel(title: "Explorar archivos", icon: "folder") }
                                .accessibilityIdentifier("browseLocalCopy:" + copy.id)
                            Button(role: .destructive) { deleting = copy } label: {
                                CompactActionLabel(title: "Eliminar copia de Sonora", icon: "trash", destructive: true)
                            }.accessibilityIdentifier("deleteLocalCopy:" + copy.id)
                        }.disabled(imports.isImporting || removing || player.isDeletingFiles)
                    }.padding(.vertical, 6)
                }
                if imports.copies.isEmpty { Text("Todavía no has importado carpetas. Tus fuentes de Archivos siguen disponibles en la biblioteca.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Copias en Sonora")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): imports.start(url, library: player.library)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { imports.issue = error.localizedDescription }
            }
        }
        .confirmationDialog("¿Eliminar esta copia local?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Eliminar copia de Sonora", role: .destructive) {
                guard let copy = deleting else { return }; deleting = nil; removing = true
                Task {
                    defer { removing = false }
                    do {
                        try await player.deleteLocalCopy(copy)
                    } catch { imports.issue = error.localizedDescription }
                }
            }
        } message: { Text("Se quitarán esta copia y sus referencias de Sonora. La carpeta original de Archivos o iCloud Drive se conservará.") }
        .navigationDestination(isPresented: $showFiles) { if let browsingSource { SourceFolderView(player: player, sourceID: browsingSource) } }
        .onChange(of: phase) { if phase == .background { imports.cancel() } }
    }
}
