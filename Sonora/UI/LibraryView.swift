import SonoraCore
import SwiftUI

struct LibraryView: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var sheet: LibrarySheet?
    @State private var showPlayer = false
    @State private var showOpenedFileAfterDismissal = false
    @State private var reset = false
    @State private var categoryDestination: LibraryCategory?
    @State private var selectedAlbum: CollectionGroup?
    @State private var showAlbum = false
    @State private var miniPlayerHeight: CGFloat = 0
    private enum LibraryCategory: Hashable { case artists, albums, songs }
    private var library: MusicLibrary { player.library }
    private var theme: PlayerTheme { PlayerTheme(scheme) }
    private enum LibrarySheet: String, Identifiable {
        case sources, addMusic, settings, queue
        var id: Self { self }
    }

    var body: some View {
        TabView {
            playerTab {
                home
                    .navigationTitle("Biblioteca")
                    .navigationDestination(item: $categoryDestination) { category in
                        switch category {
                        case .artists: CollectionGroupsView(player: player, albums: false)
                        case .albums: CollectionGroupsView(player: player, albums: true)
                        case .songs: CollectionSongList(player: player, title: "Canciones", ids: library.allSongs.map(\.id))
                        }
                    }
                    .navigationDestination(isPresented: $showAlbum) {
                        if let album = selectedAlbum {
                            CollectionSongList(player: player, title: album.title, ids: album.songIDs, group: album, albumGroup: true)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Fuentes", systemImage: "folder") { sheet = .sources }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("librarySources")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Ajustes", systemImage: "gearshape") { sheet = .settings }
                        }
                        if #available(iOS 26.0, *) {
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Añadir música", systemImage: "plus") { sheet = .addMusic }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("addMusic")
                        }
                    }
            }
            .tabItem { Label("Biblioteca", systemImage: "music.note.house") }
            playerTab { PlaylistsView(player: player) }
                .tabItem { Label("Listas", systemImage: "music.note.list") }
            playerTab { LibrarySearchView(player: player) }
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
        }
        .sheet(item: $sheet, onDismiss: {
            if showOpenedFileAfterDismissal { showOpenedFileAfterDismissal = false; showPlayer = true }
        }) { destination in
            switch destination {
            case .sources: LibrarySourcesView(player: player)
            case .addMusic: AddMusicView(player: player)
            case .settings: SettingsView(player: player)
            case .queue: QueueView(player: player)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) { NowPlayingView(player: player) }
        .onChange(of: player.openedAudioFileID, initial: true) {
            guard player.openedAudioFileID != nil else { return }
            if sheet != nil { showOpenedFileAfterDismissal = true; sheet = nil }
            else { showPlayer = true }
        }
        .tint(theme.accent)
        .onChange(of: phase) { if phase == .background { player.localImports.cancel() } }
    }

    @ViewBuilder private func playerTab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            NavigationStack { content() }
                .environment(\.miniPlayerBottomInset, player.current == nil ? 0 : miniPlayerHeight)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    miniPlayer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if height > 0 { miniPlayerHeight = height }
                        }
                }
        } else {
            VStack(spacing: 0) {
                NavigationStack { content() }
                miniPlayer
            }
            .background(theme.background)
        }
    }

    private var home: some View {
        List {
            Section {
                if library.state.sources.isEmpty {
                    Text("Tu biblioteca empieza aquí. Añade una carpeta de Archivos, una copia local o un enlace.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(library.state.songs.count) canciones · \(library.state.sources.count) fuentes")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("librarySummary")
                }
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            LibraryImportProgress(player: player)
            if player.isLoading {
                Section {
                    HStack { ProgressView("Preparando fuente…"); Spacer(); Button("Cancelar") { player.cancelLoading() } }
                }
            }
            if library.isIndexing { Section { ProgressView("Leyendo información · \(library.progress)") } }
            if let issue = library.issue {
                Section {
                    Text(issue).foregroundStyle(.secondary)
                    if library.needsReset { Button("Restablecer biblioteca", role: .destructive) { reset = true } }
                    else { Button("Cerrar aviso") { library.issue = nil } }
                }
            }
            if let issue = player.issue { Section { Text(issue); Button("Cerrar aviso de reproducción") { player.issue = nil } } }
            Section {
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    category("Artistas", icon: "music.mic", destination: .artists)
                    category("Álbumes", icon: "square.stack", destination: .albums)
                    category("Canciones", icon: "music.note", destination: .songs)
                }.buttonStyle(.plain)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            LibraryAlbumShelf(player: player) { selectedAlbum = $0; showAlbum = true }
            Section {
                NavigationLink { CollectionFavoritesView(player: player) } label: { Label("Favoritos", systemImage: "heart") }
                NavigationLink { ListeningHistoryView(player: player) } label: { Label("Historial", systemImage: "clock") }
                NavigationLink { LocalMusicView(player: player) } label: { Label("Copias en Sonora", systemImage: "arrow.down.circle") }
            }.listRowBackground(theme.surface)
        }
        .listSectionSpacing(16)
        .miniPlayerContentMargins()
        .accessibilityIdentifier("libraryHome")
        .scrollContentBackground(.hidden).background(theme.background)
        .confirmationDialog("¿Restablecer la biblioteca?", isPresented: $reset, titleVisibility: .visible) {
            Button("Restablecer biblioteca", role: .destructive) { library.reset() }
        } message: { Text("Se eliminarán las referencias, las listas, los favoritos y el historial guardados. Tus archivos de música se conservarán.") }
    }
    private func category(_ title: String, icon: String, destination: LibraryCategory) -> some View {
        Button { categoryDestination = destination } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(theme.accent)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, minHeight: 70).padding(.vertical, 4)
                .background(theme.surface, in: .rect(cornerRadius: 12))
        }
    }
    @ViewBuilder private var miniPlayer: some View {
        if player.current != nil {
            MiniPlayer(player: player, openPlayer: { showPlayer = true }, openQueue: { sheet = .queue })
        }
    }
}

private struct MiniPlayerBottomInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var miniPlayerBottomInset: CGFloat {
        get { self[MiniPlayerBottomInsetKey.self] }
        set { self[MiniPlayerBottomInsetKey.self] = newValue }
    }
}

extension View {
    /// Reserve scrollable space, leaving the viewport free to draw behind the glass.
    func miniPlayerContentMargins(isEnabled: Bool = true) -> some View {
        modifier(MiniPlayerContentMargins(isEnabled: isEnabled))
    }
}

private struct MiniPlayerContentMargins: ViewModifier {
    @Environment(\.miniPlayerBottomInset) private var inset
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, isEnabled && inset > 0 ? inset + 12 : nil, for: .scrollContent)
    }
}

private struct LibraryAlbumShelf: View {
    let player: PlaybackController
    let openAlbum: (CollectionGroup) -> Void
    private var recent: [CollectionGroup] {
        let albums = Dictionary(uniqueKeysWithValues: player.library.albums.map { ($0.id, $0) })
        var seen: Set<String> = []
        return player.library.state.history.compactMap { event in
            guard let id = player.library.state.songs[event.songID]?.albumID, seen.insert(id).inserted else { return nil }
            return albums[id]
        }
    }
    var body: some View {
        let recentAlbums = recent
        let displayed = Array((recentAlbums.isEmpty ? player.library.albums : recentAlbums).prefix(6))
        if !displayed.isEmpty {
            Section(recentAlbums.isEmpty ? "Tus álbumes" : "Escuchado recientemente") {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(displayed) { album in
                            Button { openAlbum(album) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CachedCollectionArtwork(library: player.library, song: album.songIDs.first.flatMap { player.library.state.songs[$0] })
                                        .frame(width: 150, height: 150)
                                    Text(album.title).font(.headline).lineLimit(2)
                                    Text(album.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width: 150, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
            }.listRowBackground(Color.clear)
        }
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
