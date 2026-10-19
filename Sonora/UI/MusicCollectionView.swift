import SonoraCore
import SwiftUI

struct CollectionGroupsView: View {
    let player: PlaybackController
    let albums: Bool
    @State private var volumeSelection: VolumeAnalysisSelection?
    private var groups: [CollectionGroup] { albums ? player.library.albums : player.library.artists }
    var body: some View {
        Group {
            if groups.isEmpty { ContentUnavailableView(albums ? "Sin álbumes" : "Sin artistas", systemImage: albums ? "square.stack" : "music.mic", description: Text("La información aparecerá al analizar tus archivos locales o reproducir los que estén en iCloud.")) }
            else if albums {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(groups) { group in
                            NavigationLink {
                                CollectionSongList(player: player, title: group.title, ids: group.songIDs, group: group, albumGroup: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CachedCollectionArtwork(library: player.library, song: group.songIDs.first.flatMap { player.library.state.songs[$0] }).aspectRatio(1, contentMode: .fit)
                                    Text(group.title).font(.headline).lineLimit(2)
                                    Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("library-album:" + group.id).contextMenu {
                                Button("Reproducir", systemImage: "play") { player.playSongs(group.songIDs) }
                                Button("Analizar volumen", systemImage: "waveform") {
                                    volumeSelection = .init(tracks: group.songIDs.compactMap { player.library.state.songs[$0]?.audioTrack }, album: true)
                                }
                                Button(player.library.state.favoriteAlbums.contains(group.id) ? "Quitar de favoritos" : "Marcar como favorito", systemImage: "heart") { player.library.toggleAlbum(group.id) }
                            }
                        }
                    }.padding(20)
                }
            } else {
                List(groups) { group in
                    NavigationLink { ArtistCollectionView(player: player, artist: group) } label: {
                        VStack(alignment: .leading) { Text(group.title); Text(group.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.contextMenu {
                        Button(player.library.state.favoriteArtists.contains(group.id) ? "Quitar de favoritos" : "Marcar como favorito", systemImage: "heart") { player.library.toggleArtist(group.id) }
                    }
                }
            }
        }.navigationTitle(albums ? "Álbumes" : "Artistas")
            .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
    }
}

struct ArtistCollectionView: View {
    let player: PlaybackController
    let artist: CollectionGroup
    @State private var editing = false
    private var artistTitle: String { artist.songIDs.first.flatMap { player.library.state.songs[$0]?.artist } ?? artist.title }
    private var albums: [CollectionGroup] {
        let ids = Set(artist.songIDs)
        return player.library.albums.filter { !$0.songIDs.allSatisfy { !ids.contains($0) } }
    }
    var body: some View {
        List {
            Section {
                Button("Reproducir", systemImage: "play.fill") { player.playSongs(artist.songIDs) }
                Button("Editar artista", systemImage: "pencil") { editing = true }.accessibilityIdentifier("editArtist")
                NavigationLink("Todas las canciones") { CollectionSongList(player: player, title: artistTitle, ids: artist.songIDs) }
            }
            Section("Discografía local") {
                ForEach(albums) { album in
                    NavigationLink { CollectionSongList(player: player, title: album.title, ids: album.songIDs, group: album, albumGroup: true) } label: {
                        HStack(spacing: 12) {
                            CachedCollectionArtwork(library: player.library, song: album.songIDs.first.flatMap { player.library.state.songs[$0] }).frame(width: 64, height: 64)
                            VStack(alignment: .leading) { Text(album.title); Text(songCount(album.songIDs.count)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle(artistTitle)
        .sheet(isPresented: $editing) {
            BulkMetadataEditorView(player: player, tracks: artist.songIDs.compactMap { player.library.state.songs[$0]?.audioTrack }, context: .artist(artistTitle))
        }
        .toolbar { Button { player.library.toggleArtist(artist.id) } label: { Image(systemName: player.library.state.favoriteArtists.contains(artist.id) ? "heart.fill" : "heart") }.accessibilityLabel("Artista favorito") }
    }
}

struct CollectionFavoritesView: View {
    let player: PlaybackController
    private var library: MusicLibrary { player.library }
    var body: some View {
        List {
            Section("Canciones") { CollectionRows(player: player, songs: library.allSongs.filter { library.state.favorites.contains($0.id) }) }
            Section("Álbumes") {
                ForEach(library.albums.filter { library.state.favoriteAlbums.contains($0.id) }) { album in
                    NavigationLink(album.title) { CollectionSongList(player: player, title: album.title, ids: album.songIDs, group: album, albumGroup: true) }
                }
            }
            Section("Artistas") {
                ForEach(library.artists.filter { library.state.favoriteArtists.contains($0.id) }) { artist in NavigationLink(artist.title) { ArtistCollectionView(player: player, artist: artist) } }
            }
            if library.state.favorites.isEmpty && library.state.favoriteAlbums.isEmpty && library.state.favoriteArtists.isEmpty {
                ContentUnavailableView("Tus favoritos", systemImage: "heart", description: Text("Marca canciones, álbumes o artistas desde sus opciones."))
            }
        }.navigationTitle("Favoritos")
    }
}

struct PlaylistsView: View {
    let player: PlaybackController
    @State private var editingName = false
    @State private var name = ""
    @State private var editedID: String?
    @State private var importing = false
    @State private var exporting: PlaylistExportSelection?
    @State private var pendingPlaylist: String?
    @State private var songPicker: PlaylistSongSelection?
    var body: some View {
        List {
            ForEach(player.library.state.playlists) { playlist in
                NavigationLink {
                    CollectionSongList(player: player, title: playlist.name, ids: playlist.songIDs, playlistID: playlist.id)
                } label: { VStack(alignment: .leading) { Text(playlist.name); Text(songCount(playlist.songIDs.count)).font(.caption).foregroundStyle(.secondary) } }
                    .contextMenu {
                        Button("Renombrar") { editedID = playlist.id; name = playlist.name; editingName = true }
                        Button("Exportar playlist", systemImage: "square.and.arrow.up") { exporting = .init(id: playlist.id, name: playlist.name) }
                        Button("Eliminar playlist", role: .destructive) { player.library.deletePlaylist(playlist.id) }
                    }
            }.onDelete { offsets in
                let ids = offsets.compactMap { player.library.state.playlists.indices.contains($0) ? player.library.state.playlists[$0].id : nil }
                ids.forEach(player.library.deletePlaylist)
            }
            if player.library.state.playlists.isEmpty { ContentUnavailableView("Tus listas", systemImage: "music.note.list", description: Text("Crea una lista y elige las canciones que quieras incluir.")) }
        }
        .navigationTitle("Listas")
        .toolbar {
            Button("Importar playlist", systemImage: "square.and.arrow.down") { importing = true }
            Button("Nueva lista", systemImage: "plus") { editedID = nil; name = ""; editingName = true }
        }
        .sheet(isPresented: $importing) { PlaylistImportView(player: player) }
        .sheet(item: $exporting) { PlaylistExportView(player: player, playlist: $0) }
        .sheet(item: $songPicker) { PlaylistSongPicker(player: player, playlistID: $0.id) }
        .sheet(isPresented: $editingName, onDismiss: {
            if let pendingPlaylist { songPicker = .init(id: pendingPlaylist); self.pendingPlaylist = nil }
        }) {
            PlaylistNameEditor(initialName: name, renaming: editedID != nil) { value in
                if let editedID { player.library.renamePlaylist(editedID, name: value) } else { pendingPlaylist = player.library.createPlaylist(value) }
            }
        }
    }
}

struct ListeningHistoryView: View {
    let player: PlaybackController
    @State private var clear = false
    var body: some View {
        List {
            ForEach(player.library.state.history) { event in
                if let song = player.library.state.songs[event.songID] {
                    Button { player.playSongs([song.id]) } label: {
                        VStack(alignment: .leading) { Text(song.title).foregroundStyle(.primary); Text(event.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if player.library.state.history.isEmpty { ContentUnavailableView("Todavía no has escuchado música", systemImage: "clock", description: Text("Aquí aparecerán tus últimas 500 canciones reproducidas.")) }
        }
        .navigationTitle("Historial")
        .toolbar { Button("Borrar historial", role: .destructive) { clear = true }.disabled(player.library.state.history.isEmpty) }
        .confirmationDialog("¿Borrar el historial?", isPresented: $clear, titleVisibility: .visible) { Button("Borrar historial", role: .destructive) { player.library.clearHistory() } }
    }
}

struct CachedCollectionArtwork: View {
    let library: MusicLibrary
    let song: CollectionSong?
    var cornerRadius: CGFloat = 12
    @State private var image: UIImage?
    var body: some View {
        ArtworkView(image: image, cornerRadius: cornerRadius)
            .task(id: song?.artworkKey) {
                guard let key = song?.artworkKey, key == (key as NSString).lastPathComponent else { image = nil; return }
                let url = library.artworkDirectory.appendingPathComponent(key)
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                guard !Task.isCancelled else { return }
                image = data.flatMap(UIImage.init(data:))
            }
    }
}
