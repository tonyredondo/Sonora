import SonoraCore
import SwiftUI

struct SourceFolderView: View {
    let player: PlaybackController
    let sourceID: String
    var path = ""
    @State private var entries: [SourceFile] = []
    @State private var loading = true
    @State private var loadID = UUID()
    @State private var issue: String?
    @State private var deleting: SourceFile?
    @State private var confirmDeletion = false
    private var library: MusicLibrary { player.library }
    private var title: String {
        path.isEmpty ? library.state.sources.first { $0.id == sourceID }?.name ?? "Archivos" : (path as NSString).lastPathComponent
    }
    private var localCopy: Bool {
        (try? library.sourceURL(sourceID)).flatMap { player.localImports.copy(containing: $0) } != nil
    }
    private var songs: [CollectionSong] {
        library.state.songs.values.filter {
            $0.sourceID == sourceID && (path.isEmpty || $0.relativePath.hasPrefix(path + "/"))
        }.sorted {
            if $0.relativePath == $1.relativePath { return ($0.cue?.number ?? 0) < ($1.cue?.number ?? 0) }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    var body: some View {
        let songs = songs
        let playable = Set(songs.map(\.relativePath))
        List {
            if !songs.isEmpty {
                Section {
                    Button("Reproducir carpeta", systemImage: "play.fill") { player.playSongs(songs.map(\.id)) }
                    Button("Añadir carpeta a la cola", systemImage: "text.badge.plus") { player.enqueueSongs(songs.map(\.id), playNext: false) }
                }
            }
            if loading { ProgressView("Leyendo archivos…") }
            if let message = issue ?? player.issue {
                Section {
                    Text(message).accessibilityIdentifier("sourceFilesError")
                    Button("Volver a cargar") { issue = nil; player.issue = nil; Task { await reload() } }
                    Button("Cerrar aviso") { issue = nil; player.issue = nil }
                }
            }
            Section {
                ForEach(entries) { item in
                    HStack(spacing: 8) {
                        if item.isDirectory {
                            NavigationLink {
                                SourceFolderView(player: player, sourceID: sourceID, path: item.relativePath)
                            } label: { information(item) }
                                .accessibilityIdentifier("source-file:" + item.relativePath)
                        } else if playable.contains(item.relativePath) {
                            Button {
                                if let song = songs.first(where: { $0.relativePath == item.relativePath }) { player.playSongs(songs.map(\.id), startingAt: song.id) }
                            } label: { information(item) }.buttonStyle(.plain)
                                .accessibilityIdentifier("source-file:" + item.relativePath)
                        } else { information(item) }
                        Menu {
                            Button(item.isDirectory ? "Eliminar carpeta" : "Eliminar archivo", systemImage: "trash", role: .destructive) { confirm(item) }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Opciones de " + item.name)
                            .accessibilityIdentifier("file-options:" + item.relativePath)
                    }
                    .contextMenu {
                        Button(item.isDirectory ? "Eliminar carpeta" : "Eliminar archivo", systemImage: "trash", role: .destructive) { confirm(item) }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Eliminar", systemImage: "trash", role: .destructive) { confirm(item) }
                    }
                }
                if entries.isEmpty && !loading && issue == nil {
                    ContentUnavailableView("Carpeta vacía", systemImage: "folder", description: Text("No hay archivos en esta carpeta."))
                }
            } header: { Text("Archivos") }
            footer: { Text("Puedes borrar archivos y subcarpetas desde sus opciones o deslizando su fila.") }
        }
        .disabled(player.isDeletingFiles)
        .overlay { if player.isDeletingFiles { ProgressView("Eliminando y actualizando biblioteca…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: player.isDeletingFiles) { if !player.isDeletingFiles { Task { await reload() } } }
        .alert("¿Eliminar «\(deleting?.name ?? "")»?", isPresented: $confirmDeletion, presenting: deleting) { item in
            Button(item.isDirectory ? "Eliminar carpeta" : "Eliminar archivo", role: .destructive) {
                Task {
                    do { try await player.deleteSourceFile(item, sourceID: sourceID) }
                    catch { issue = "No se pudo completar el borrado: \(error.localizedDescription)" }
                    await reload()
                }
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: { item in
            let contents = item.isDirectory ? "Se borrará la carpeta con todos sus archivos y subcarpetas." : "Se borrará este archivo."
            let location = localCopy ? "Se eliminará de la copia guardada en Sonora. El contenido original de la transferencia o de Archivos se conservará." : "Se eliminará el original de Archivos o iCloud Drive. El borrado en iCloud se sincroniza con tus dispositivos."
            Text(contents + " " + location + " Sus canciones se retirarán de la biblioteca, las playlists y la cola. No se puede deshacer desde Sonora.")
        }
    }
    private func information(_ item: SourceFile) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).foregroundStyle(.primary).lineLimit(3)
                Text(item.isDirectory ? "Carpeta" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.fingerprint.size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: { Image(systemName: item.isDirectory ? "folder" : "doc") }
    }
    private func confirm(_ item: SourceFile) { deleting = item; confirmDeletion = true }
    @MainActor private func reload() async {
        let token = UUID(); loadID = token; loading = true
        defer { if loadID == token { loading = false } }
        do {
            let values = try await SourceFileService.contents(in: library.access(sourceID), path: path)
            guard loadID == token else { return }
            entries = values
        } catch {
            guard loadID == token else { return }
            entries = []; issue = "No se pudo leer esta carpeta: \(error.localizedDescription)"
        }
    }
}
