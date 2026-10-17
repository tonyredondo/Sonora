import SonoraCore
import SwiftUI

struct LibraryView: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var sheet: LibrarySheet?
    @State private var showPlayer = false
    @State private var reset = false
    private var library: MusicLibrary { player.library }
    private var theme: PlayerTheme { PlayerTheme(scheme) }
    private enum LibrarySheet: String, Identifiable {
        case sources, settings, queue
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                List {
                    if !query.isEmpty {
                        let songs = library.allSongs.filter { $0.matches(query) }
                        if songs.isEmpty {
                            ContentUnavailableView.search(text: query)
                        } else {
                            CollectionRows(player: player, songs: songs)
                        }
                    } else {
                        Section {
                            if library.state.sources.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Tu biblioteca", systemImage: "music.note.house").font(.headline)
                                    Text("Añade carpetas de Archivos o iCloud Drive para reunir tus canciones, álbumes y artistas.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button("Añadir fuente", systemImage: "folder.badge.plus") { sheet = .sources }
                                        .buttonStyle(.bordered).frame(minHeight: 44)
                                }.padding(.vertical, 8)
                            } else {
                                Text("\(library.state.songs.count) \(library.state.songs.count == 1 ? "canción" : "canciones") · \(library.state.sources.count) \(library.state.sources.count == 1 ? "fuente" : "fuentes")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("librarySummary")
                            }
                        }.listRowBackground(theme.surface)
                        Section {
                            NavigationLink { CollectionGroupsView(player: player, albums: false) } label: { Label("Artistas", systemImage: "music.mic") }
                            NavigationLink { CollectionGroupsView(player: player, albums: true) } label: { Label("Álbumes", systemImage: "square.stack") }
                            NavigationLink { CollectionSongList(player: player, title: "Canciones", ids: library.allSongs.map(\.id)) } label: { Label("Canciones", systemImage: "music.note") }
                        }.listRowBackground(theme.surface)
                        Section {
                            NavigationLink { CollectionFavoritesView(player: player) } label: { Label("Favoritos", systemImage: "heart") }
                            NavigationLink { PlaylistsView(player: player) } label: { Label("Playlists", systemImage: "music.note.list") }
                            NavigationLink { ListeningHistoryView(player: player) } label: { Label("Historial", systemImage: "clock") }
                            NavigationLink { LocalMusicView(player: player) } label: { Label("Copias locales", systemImage: "arrow.down.circle") }
                        }.listRowBackground(theme.surface)
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
                    if library.isIndexing { Section { ProgressView("Leyendo información · \(library.progress)") } }
                    else if !library.progress.isEmpty { Text(library.progress).font(.footnote).foregroundStyle(.secondary) }
                    if let issue = library.issue {
                        Section {
                            Text(issue).foregroundStyle(.secondary)
                            if library.needsReset { Button("Restablecer biblioteca", role: .destructive) { reset = true } }
                            else { Button("Cerrar aviso") { library.issue = nil } }
                        }
                    }
                    if let issue = player.issue {
                        Section { Text(issue); Button("Cerrar aviso de reproducción") { player.issue = nil } }
                    }
                }
                .accessibilityIdentifier("libraryHome")
                .scrollContentBackground(.hidden).background(theme.background)
                .navigationTitle("Biblioteca")
                .searchable(text: $query, prompt: "Canciones, artistas, álbumes o etiquetas")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fuentes", systemImage: "folder.badge.gearshape") { sheet = .sources }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { sheet = .settings } label: { Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Ajustes")
                    }
                }
                .confirmationDialog("¿Restablecer la biblioteca?", isPresented: $reset, titleVisibility: .visible) {
                    Button("Restablecer biblioteca", role: .destructive) { library.reset() }
                } message: { Text("Se eliminarán las referencias, las playlists, los favoritos y el historial guardados. Tus archivos de música se conservarán.") }
            }
            if player.current != nil {
                MiniPlayer(player: player, openPlayer: { showPlayer = true }, openQueue: { sheet = .queue })
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .sources: LibrarySourcesView(player: player)
            case .settings: SettingsView(player: player)
            case .queue: QueueView(player: player)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) { NowPlayingView(player: player) }
        .tint(theme.accent)
    }
}

struct TrackRow: View {
    let player: PlaybackController
    let track: AudioTrack
    var showsLocation = false
    @Environment(\.colorScheme) private var scheme

    private var song: CollectionSong? {
        guard let song = player.libraryID(for: track).flatMap({ player.library.state.songs[$0] }) else { return nil }
        // Before indexing completes, keep prepared metadata instead of replacing
        // it with the library's filename/unknown-artist placeholder.
        guard song.modified != nil || player.details[track.id] == nil else { return nil }
        return song
    }
    // Playback details are bounded and invalidated after edits. The library owns
    // the list metadata, including songs that have not been played yet.
    var title: String { song?.title ?? player.details[track.id]?.title ?? track.displayName }
    var subtitle: String {
        if showsLocation { return player.location(for: track) }
        return song?.artist ?? player.details[track.id]?.artist ?? "Artista desconocido"
    }
    private var selected: Bool { track.id == player.current?.id }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let song, song.modified != nil || song.artworkKey != nil {
                    CachedCollectionArtwork(library: player.library, song: song, cornerRadius: 7)
                } else {
                    ArtworkView(image: player.details[track.id]?.artwork, cornerRadius: 7)
                }
            }.frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(selected ? PlayerTheme(scheme).accent : .primary).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected { Image(systemName: "waveform").foregroundStyle(PlayerTheme(scheme).accent).accessibilityLabel("Tema actual") }
        }.padding(.vertical, 4).contentShape(.rect)
    }
}
