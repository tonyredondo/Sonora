import SwiftUI
import UniformTypeIdentifiers

struct AddMusicView: View {
    let player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var chooseFolder = false
    @State private var copyFolder = false
    @State private var link = false
    private var busy: Bool { player.isLoading || player.localImports.isImporting || player.linkImports.hasPendingImport || player.isDeletingFiles }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("Vincular carpeta", subtitle: "Desde Archivos o iCloud. La música permanece en su carpeta original.", icon: "folder.badge.plus") { copyFolder = false; chooseFolder = true }
                        .accessibilityIdentifier("linkMusicFolder")
                    choice("Copiar carpeta a Sonora", subtitle: "Guarda una copia para escuchar sin conexión. El original se conserva.", icon: "arrow.down.circle") { copyFolder = true; chooseFolder = true }
                        .accessibilityIdentifier("copyMusicFolder")
                    choice("Descargar enlace", subtitle: "Descarga y descomprime un WeTransfer en Sonora.", icon: "link") { link = true }
                        .accessibilityIdentifier("addLinkSource")
                }.disabled(busy)
                LibraryImportProgress(player: player)
                if player.isLoading { ProgressView("Preparando fuente…") }
                if let issue = player.issue { Text(issue).foregroundStyle(.red) }
                Section {
                    Text("Todas las opciones añaden la música a tu biblioteca, incluidas las subcarpetas. Gestiona las carpetas desde Fuentes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Añadir música").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .sheet(isPresented: $link) { LinkImportView(imports: player.linkImports) }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    if copyFolder { player.localImports.start(url, library: player.library) }
                    else { player.addFolderToLibrary(url) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { player.issue = error.localizedDescription }
                }
            }
        }
    }
    private func choice(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            } icon: { Image(systemName: icon) }
        }.buttonStyle(.plain)
    }
}

/// Import status remains visible when the user returns to the library.
struct LibraryImportProgress: View {
    let player: PlaybackController
    var body: some View {
        if player.linkImports.hasPendingImport || player.linkImports.issue != nil {
            Section("Descarga") { LinkImportStatusView(imports: player.linkImports) }
        }
        if player.localImports.isImporting {
            Section("Copiando música") {
                if let progress = player.localImports.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("\(progress.completed) de \(progress.total) archivos").font(.subheadline)
                    Text(progress.filename).font(.caption).foregroundStyle(.secondary)
                } else { ProgressView("Revisando carpeta…") }
                Button("Cancelar importación", role: .cancel) { player.localImports.cancel() }
            }
        }
        if let issue = player.localImports.issue {
            Section { Text(issue); Button("Cerrar aviso de importación") { player.localImports.issue = nil } }
        }
        if let id = player.localImports.completedCopyID,
           let copy = player.localImports.copies.first(where: { $0.id == id }),
           let sourceID = player.library.sourceID(matching: player.localImports.musicURL(copy)) {
            Section {
                Label("Añadido: \(copy.name)", systemImage: "checkmark.circle")
                NavigationLink("Ver música añadida") {
                    CollectionSongList(player: player, title: copy.name,
                                       ids: player.library.allSongs.filter { $0.sourceID == sourceID }.map(\.id), sourceID: sourceID)
                }
            }
        }
    }
}
