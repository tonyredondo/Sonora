import SonoraCore
import SwiftUI
import UniformTypeIdentifiers

struct PlaylistImportView: View {
    let player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var choosingFolder = false
    @State private var document: PlaylistImportDocument?
    @State private var report: PlaylistImportReport?
    @State private var working = false
    @State private var issue: String?
    @State private var work: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Elegir archivo M3U o M3U8", systemImage: "doc") { choosingFolder = false; choosing = true }
                        .disabled(working).accessibilityIdentifier("chooseM3U")
                    if let document { Text(document.url.lastPathComponent).font(.headline) }
                } footer: { Text("Después elige la carpeta que contiene la música para autorizar el acceso a sus archivos. Se respetan las rutas y el orden de la lista.") }
                if document != nil, report == nil {
                    Section { Button("Elegir carpeta de música", systemImage: "folder") { choosingFolder = true; choosing = true }.disabled(working) }
                }
                if working {
                    ProgressView("Leyendo playlist…")
                    Button("Cancelar lectura", role: .cancel) { work?.cancel() }
                }
                if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
                if let report {
                    Section {
                        Label("Importadas \(report.imported) canciones", systemImage: "checkmark.circle").accessibilityIdentifier("playlistImportResult")
                        NavigationLink("Ver playlist") { CollectionSongList(player: player, title: document?.name ?? "Playlist", ids: [], playlistID: report.playlistID) }
                    }
                    if !report.problems.isEmpty {
                        Section("Entradas no añadidas") {
                            ForEach(report.problems) { problem in
                                VStack(alignment: .leading) { Text(problem.path); Text(problem.reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.navigationTitle("Importar playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Listo") { dismiss() }.disabled(working) }
                .fileImporter(isPresented: $choosing, allowedContentTypes: choosingFolder ? [.folder] : [UTType(filenameExtension: "m3u") ?? .item, UTType(filenameExtension: "m3u8") ?? .item]) { result in
                    do {
                        let url = try result.get(), folder = choosingFolder
                        working = true; issue = nil
                        work = Task {
                            defer { working = false; work = nil }
                            do {
                                if folder, let document { report = try await PlaylistExchange.importPlaylist(document, folder: url, library: player.library) }
                                else { document = try await PlaylistExchange.read(url); report = nil }
                            } catch is CancellationError { }
                            catch { issue = error.localizedDescription }
                        }
                    } catch { if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription } }
                }
                .interactiveDismissDisabled(working)
                .onDisappear { work?.cancel() }
                .onChange(of: phase) { if phase == .background { work?.cancel() } }
        }
    }
}

struct PlaylistExportSelection: Identifiable { let id: String; let name: String }
struct PlaylistExportView: View {
    let player: PlaybackController
    let playlist: PlaylistExportSelection
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var legacy = false
    @State private var choosing = false
    @State private var working = false
    @State private var saved: URL?
    @State private var issue: String?
    @State private var work: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name).accessibilityIdentifier("exportPlaylistName")
                    Picker("Formato", selection: $legacy) { Text("M3U8 · UTF-8").tag(false); Text("M3U · UTF-8").tag(true) }
                    Button("Elegir carpeta y guardar", systemImage: "square.and.arrow.up") { choosing = true }
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("saveM3U")
                } footer: { Text("Guarda la lista junto a tu música para conservar sus rutas relativas al mover la carpeta. La lista contiene referencias; no incluye copias del audio. Si ya existe una con ese nombre, se crea otra.") }
                if player.library.state.playlists.first(where: { $0.id == playlist.id })?.songIDs.contains(where: { player.library.state.songs[$0]?.cue != nil }) == true {
                    Section { Text("Los temas CUE incluyen límites de tiempo de VLC. Sonora los conserva al importar; otros reproductores pueden ignorar esos límites y reproducir el archivo completo.").font(.footnote).foregroundStyle(.secondary) }
                }
                if working { ProgressView("Guardando playlist…"); Button("Cancelar exportación", role: .cancel) { work?.cancel() } }
                if let saved { Section("Playlist guardada") { Label(saved.lastPathComponent, systemImage: "checkmark.circle").accessibilityIdentifier("playlistExportResult") } }
                if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
            }.navigationTitle("Exportar playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Listo") { dismiss() }.disabled(working) }
                .onAppear { if name.isEmpty { name = playlist.name } }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                    do {
                        let url = try result.get(); working = true; issue = nil
                        work = Task {
                            defer { working = false; work = nil }
                            do { saved = try await PlaylistExchange.exportPlaylist(playlist.id, library: player.library, folder: url, name: name, legacy: legacy) }
                            catch is CancellationError { issue = "Exportación cancelada." }
                            catch { issue = error.localizedDescription }
                        }
                    } catch { if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription } }
                }
                .interactiveDismissDisabled(working)
                .onDisappear { work?.cancel() }
                .onChange(of: phase) { if phase == .background { work?.cancel() } }
        }
    }
}
