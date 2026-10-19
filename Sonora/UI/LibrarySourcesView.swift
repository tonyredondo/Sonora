import SonoraCore
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySourcesView: View {
    let player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var addMusic = false
    @State private var removing: CollectionSource?
    @State private var confirmRemoval = false
    @State private var deletingCopy: ImportedMusicRecord?
    @State private var confirmCopyDeletion = false
    private var library: MusicLibrary { player.library }

    var body: some View {
        let counts = library.state.songs.values.reduce(into: [String: Int]()) { $0[$1.sourceID, default: 0] += 1 }
        NavigationStack {
            List {
                Section {
                    Button("Añadir música", systemImage: "plus.circle.fill") { addMusic = true }
                    NavigationLink { LocalMusicView(player: player) } label: { Label("Copias en Sonora", systemImage: "internaldrive") }
                }
                Section {
                    ForEach(library.state.sources) { source in
                        HStack {
                            NavigationLink {
                                CollectionSongList(player: player, title: source.name,
                                    ids: library.allSongs.filter { $0.sourceID == source.id }.map(\.id), sourceID: source.id)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.name)
                                        let count = counts[source.id, default: 0]
                                        Text("\(count) \(count == 1 ? "canción" : "canciones")").font(.caption).foregroundStyle(.secondary)
                                        Text(isLocalCopy(source) ? "Copia de Sonora · Sin conexión" : "Carpeta vinculada · Archivos / iCloud")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "folder") }
                            }.accessibilityIdentifier("source:" + source.name)
                            Menu {
                                NavigationLink { SourceFolderView(player: player, sourceID: source.id) } label: { Label("Explorar archivos", systemImage: "folder") }
                                Button("Actualizar fuente", systemImage: "arrow.clockwise") {
                                    do { player.addFolderToLibrary(try library.sourceURL(source.id)) }
                                    catch { player.issue = "Vuelve a añadir esta carpeta para recuperar el acceso: \(error.localizedDescription)" }
                                }.disabled(player.isLoading)
                                Button("Quitar de la biblioteca", systemImage: "minus.circle", role: .destructive) {
                                    removing = source; confirmRemoval = true
                                }
                                if let url = try? library.sourceURL(source.id), let copy = player.localImports.copy(containing: url) {
                                    Button("Eliminar copia de Sonora", systemImage: "trash", role: .destructive) { deletingCopy = copy; confirmCopyDeletion = true }
                                }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                .accessibilityLabel("Opciones de la fuente \(source.name)")
                                .accessibilityIdentifier("source-options:" + source.name)
                        }
                    }
                } header: { Text("Carpetas de música") }
                footer: { Text("La biblioteca reúne la música de todas tus fuentes, incluidas sus subcarpetas. Puedes usar carpetas de Archivos, iCloud Drive y copias guardadas en Sonora.") }
                if library.state.sources.isEmpty {
                    ContentUnavailableView("Sin fuentes", systemImage: "folder", description: Text("Añade una carpeta o un enlace para empezar a llenar tu biblioteca."))
                }
                if player.linkImports.hasPendingImport || player.linkImports.issue != nil || player.linkImports.completedName != nil {
                    Section("Importación de enlace") { LinkImportStatusView(imports: player.linkImports) }
                }
                if player.isLoading {
                    Section {
                        HStack {
                            ProgressView("Preparando fuente…")
                            Spacer()
                            Button("Cancelar") { player.cancelLoading() }
                        }
                    }
                }
                if player.isDeletingFiles { Section { ProgressView("Eliminando y actualizando biblioteca…") } }
                if library.isIndexing { Section { ProgressView("Leyendo información · \(library.progress)") } }
                if let issue = player.issue { Section { Text(issue); Button("Cerrar aviso") { player.issue = nil } } }
            }
            .navigationTitle("Fuentes")
            .disabled(player.isDeletingFiles)
            .interactiveDismissDisabled(player.isDeletingFiles)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .sheet(isPresented: $addMusic) { AddMusicView(player: player) }
            .alert("¿Quitar esta fuente de la biblioteca?", isPresented: $confirmRemoval) {
                Button("Quitar de la biblioteca", role: .destructive) {
                    if let source = removing { player.forgetSource(source.id) }
                    removing = nil
                }
                Button("Cancelar", role: .cancel) { removing = nil }
            } message: {
                Text("Se quitarán las canciones de «\(removing?.name ?? "")» de la biblioteca, las playlists y la cola. Los archivos originales no se borrarán.")
            }
            .alert("¿Eliminar esta copia local?", isPresented: $confirmCopyDeletion, presenting: deletingCopy) { copy in
                Button("Eliminar copia de Sonora", role: .destructive) {
                    Task { do { try await player.deleteLocalCopy(copy) } catch { player.issue = "No se pudo eliminar la copia: \(error.localizedDescription)" } }
                }
                Button("Cancelar", role: .cancel) { deletingCopy = nil }
            } message: { copy in
                Text("Se borrará «\(copy.name)» de Sonora con todos sus archivos y subcarpetas. Sus canciones se retirarán de la biblioteca, las playlists y la cola. El contenido original de la transferencia o de Archivos se conservará.")
            }
        }
    }
    private func isLocalCopy(_ source: CollectionSource) -> Bool {
        guard let url = try? library.sourceURL(source.id) else { return false }
        return player.localImports.copy(containing: url) != nil
    }

}
