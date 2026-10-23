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
    private enum Content: String, CaseIterable, Identifiable {
        case songs, references
        var id: String { rawValue }
        var title: String { self == .songs ? "Canciones y lista" : "Solo lista M3U" }
    }
    private struct SavedExport {
        let url: URL
        let content: Content
    }
    let player: PlaybackController
    let playlist: PlaylistExportSelection
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = Content.songs
    @State private var format = PlaylistFolderExport.Format.original
    @State private var legacy = false
    @State private var choosing = false
    @State private var working = false
    @State private var saved: SavedExport?
    @State private var progress: PlaylistFolderExport.Progress?
    @State private var issue: String?
    @State private var work: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var cancelling = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name).accessibilityIdentifier("exportPlaylistName")
                    Picker("Contenido", selection: $content) {
                        ForEach(Content.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("playlistExportContent")
                    if content == .songs {
                        Picker("Formato", selection: $format) {
                            ForEach(PlaylistFolderExport.Format.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("playlistAudioFormat")
                    } else {
                        Picker("Formato", selection: $legacy) { Text("M3U8 · UTF-8").tag(false); Text("M3U · UTF-8").tag(true) }
                            .accessibilityIdentifier("playlistReferenceFormat")
                    }
                    Button("Elegir carpeta y guardar", systemImage: "square.and.arrow.up") { saved = nil; issue = nil; choosing = true }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveM3U")
                } footer: {
                    if content == .songs {
                        Text("Crea una carpeta nueva con las canciones numeradas y una lista M3U8 que conserva su orden al moverla. Incluye información, carátulas y letras disponibles. Si ya existe ese nombre, se crea otra carpeta.")
                    } else {
                        Text("Guarda la lista junto a tu música para conservar sus rutas relativas al mover la carpeta. La lista contiene referencias; no incluye copias del audio. Si ya existe una con ese nombre, se crea otra.")
                    }
                }.disabled(working)
                if content == .songs {
                    Section {
                        Text(format == .original
                            ? "Conserva el audio original. Los temas CUE se guardan como canciones WAV independientes, sin pérdida."
                            : "Convierte las canciones a MP3 a 320 kb/s constantes. Los archivos que ya son MP3 se copian sin convertirlos de nuevo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if player.library.state.playlists.first(where: { $0.id == playlist.id })?.songIDs.contains(where: { player.library.state.songs[$0]?.cue != nil }) == true {
                    Section { Text("Los temas CUE incluyen límites de tiempo de VLC. Sonora los conserva al importar; otros reproductores pueden ignorar esos límites y reproducir el archivo completo.").font(.footnote).foregroundStyle(.secondary) }
                }
                if working {
                    Section("Exportando") {
                        if let progress {
                            ProgressView("Exportando canciones…", value: progress.fraction).accessibilityIdentifier("playlistExportProgress")
                            Text("\(progress.completed) de \(progress.total) canciones").monospacedDigit()
                            Text(progress.filename).font(.caption).foregroundStyle(.secondary)
                        } else { ProgressView(content == .songs ? "Preparando canciones…" : "Guardando playlist…") }
                        Button(cancelling ? "Cancelando…" : "Cancelar exportación", role: .cancel) { cancelExport() }
                            .disabled(cancelling)
                            .accessibilityIdentifier("cancelPlaylistExport")
                    }
                }
                if let saved {
                    Section(saved.content == .songs ? "Carpeta guardada" : "Playlist guardada") {
                        Label(saved.url.lastPathComponent, systemImage: "checkmark.circle").accessibilityIdentifier("playlistExportResult")
                    }
                }
                if let issue {
                    Section { Text(issue).foregroundStyle(.secondary).accessibilityIdentifier("playlistExportError") }
                }
            }.navigationTitle("Exportar playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Listo") { dismiss() }.disabled(working) }
                .onAppear { if name.isEmpty { name = playlist.name } }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                    do {
                        startExport(to: try result.get())
                    } catch {
                        if (error as NSError).code != NSUserCancelledError { saved = nil; issue = error.localizedDescription }
                    }
                }
                .interactiveDismissDisabled(working)
                .onDisappear { cancelExport(showMessage: false) }
                .onChange(of: phase) { if phase == .background { cancelExport() } }
        }
    }

    private func startExport(to folder: URL) {
        let id = UUID(), exportName = name, exportContent = content, exportFormat = format, exportLegacy = legacy
        work?.cancel()
        operationID = id; working = true; cancelling = false; issue = nil; saved = nil; progress = nil
        work = Task { @MainActor in
            defer {
                if operationID == id { working = false; cancelling = false; work = nil; operationID = nil; progress = nil }
            }
            do {
                let url: URL
                if exportContent == .songs {
                    url = try await player.exportPlaylist(playlist.id, to: folder, name: exportName, format: exportFormat) { value in
                        Task { @MainActor in
                            guard operationID == id else { return }
                            progress = value
                        }
                    }
                } else {
                    url = try await PlaylistExchange.exportPlaylist(playlist.id, library: player.library, folder: folder, name: exportName, legacy: exportLegacy)
                }
                guard operationID == id else { return }
                saved = SavedExport(url: url, content: exportContent)
            } catch {
                guard operationID == id else { return }
                issue = error is CancellationError ? "Exportación cancelada." : error.localizedDescription
            }
        }
    }

    private func cancelExport(showMessage: Bool = true) {
        guard working else { return }
        work?.cancel(); cancelling = true
        // Wait for cleanup or the committed URL before reporting cancellation.
        // On disappearance there is no longer a view to receive that result.
        if !showMessage { work = nil; operationID = nil; working = false; progress = nil }
    }
}
