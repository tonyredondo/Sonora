import SonoraCore
import SwiftUI

private struct MetadataSelection: Identifiable {
    let id = UUID()
    let tracks: [AudioTrack]
}

struct CollectionSongList: View {
    let player: PlaybackController
    let title: String
    let ids: [String]
    var playlistID: String? = nil
    var sourceID: String? = nil
    var group: CollectionGroup? = nil
    var albumGroup = false
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var metadataSelection: MetadataSelection?
    @State private var volumeSelection: VolumeAnalysisSelection?
    @State private var forget = false
    @State private var addToPlaylist = false
    @State private var exporting: PlaylistExportSelection?
    private var library: MusicLibrary { player.library }
    private var firstSong: CollectionSong? { activeIDs.first.flatMap { library.state.songs[$0] } }
    private var displayedTitle: String { albumGroup ? firstSong?.album ?? title : title }
    private var activeIDs: [String] { playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.songIDs } ?? ids }
    private var songs: [CollectionSong] { activeIDs.compactMap { library.state.songs[$0] }.filter { $0.matches(query) } }
    var body: some View {
        List(selection: $selection) {
            if let sourceID, !editMode.isEditing {
                Section {
                    NavigationLink { SourceFolderView(player: player, sourceID: sourceID) } label: { Label("Explorar archivos", systemImage: "folder") }
                        .accessibilityIdentifier("browseSourceFiles")
                }
            }
            if albumGroup, let group, !editMode.isEditing {
                Section {
                    HStack(spacing: 16) {
                        CachedCollectionArtwork(library: library, song: activeIDs.first.flatMap { library.state.songs[$0] })
                            .frame(width: 100, height: 100)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(firstSong?.albumArtist ?? group.subtitle).font(.headline)
                            Text("\(activeIDs.count) canciones").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
            if !songs.isEmpty && !editMode.isEditing {
                Section {
                    Button("Reproducir", systemImage: "play.fill") { player.playSongs(songs.map(\.id)) }
                    Button("Añadir a la cola", systemImage: "text.badge.plus") { player.enqueueSongs(songs.map(\.id), playNext: false) }
                    if let playlistID { Button("Exportar playlist", systemImage: "square.and.arrow.up") { exporting = .init(id: playlistID, name: title) } }
                    if albumGroup {
                        Button("Editar álbum", systemImage: "pencil") {
                            metadataSelection = MetadataSelection(tracks: activeIDs.compactMap { library.state.songs[$0]?.audioTrack })
                        }.accessibilityIdentifier("editAlbum")
                    }
                    Menu("Más opciones", systemImage: "ellipsis") {
                        Button(albumGroup ? "Analizar volumen del álbum" : "Analizar volumen", systemImage: "waveform") {
                            let tracks = (albumGroup ? activeIDs : songs.map(\.id)).compactMap { library.state.songs[$0]?.audioTrack }
                            volumeSelection = .init(tracks: tracks, album: albumGroup)
                        }
                    }
                }
            }
            ForEach(songs) { song in
                Group {
                    if editMode.isEditing { CollectionSongRow(player: player, song: song, showActions: false) }
                    else {
                        CollectionSongRow(player: player, song: song, play: { player.playSongs(activeIDs, startingAt: song.id) })
                    }
                }.tag(song.id).deleteDisabled(playlistID == nil || !query.isEmpty).moveDisabled(playlistID == nil || !query.isEmpty)
            }
            .onDelete { if let playlistID { library.remove(from: playlistID, at: $0) } }
            .onMove { if let playlistID { library.move(in: playlistID, from: $0, to: $1) } }
            if songs.isEmpty { ContentUnavailableView("Sin canciones", systemImage: "music.note", description: Text(query.isEmpty ? "Añade canciones desde sus opciones en la biblioteca." : "No hay resultados para esta búsqueda.")) }
            if editMode.isEditing { Text("Selecciona canciones para añadirlas a una playlist, ponerlas en cola o editar su información en conjunto.").font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("collectionSongs")
        .environment(\.editMode, $editMode)
        .navigationTitle(playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.name } ?? displayedTitle)
        .searchable(text: $query, prompt: "Buscar canciones")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "Listo" : "Seleccionar") {
                    editMode = editMode.isEditing ? .inactive : .active
                    if !editMode.isEditing { selection = [] }
                }
            }
            if let group {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if albumGroup { library.toggleAlbum(group.id) } else { library.toggleArtist(group.id) }
                    } label: { Image(systemName: (albumGroup ? library.state.favoriteAlbums : library.state.favoriteArtists).contains(group.id) ? "heart.fill" : "heart") }.accessibilityLabel("Marcar favorito")
                }
            }
            if sourceID != nil { ToolbarItem(placement: .primaryAction) { Button("Quitar de la biblioteca", role: .destructive) { forget = true } } }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(selection.count) seleccionadas").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Seleccionar todo") { selection = Set(songs.map(\.id)) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { selectionActions }
                        VStack { selectionActions }
                    }
                }.padding().background(.bar)
            }
        }
        .sheet(item: $metadataSelection) { selected in
            if selected.tracks.count == 1, let track = selected.tracks.first { MetadataEditorView(player: player, track: track) }
            else { BulkMetadataEditorView(player: player, tracks: selected.tracks) }
        }
        .sheet(item: $exporting) { PlaylistExportView(player: player, playlist: $0) }
        .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
        .confirmationDialog("¿Quitar esta fuente de la biblioteca?", isPresented: $forget, titleVisibility: .visible) {
            Button("Quitar de la biblioteca", role: .destructive) { if let sourceID { player.forgetSource(sourceID); dismiss() } }
        } message: { Text("Se quitarán sus referencias de la biblioteca, las playlists y la cola. Los archivos originales no se borrarán.") }
        .sheet(isPresented: $addToPlaylist) { AddSongsToPlaylistView(player: player, songIDs: selectedIDs) }
    }
    private var selectedIDs: [String] { activeIDs.filter { selection.contains($0) } }
    private var selectionActions: some View {
        Group {
            Button("Editar información", systemImage: "pencil") {
                metadataSelection = MetadataSelection(tracks: selectedIDs.compactMap { library.state.songs[$0]?.audioTrack })
            }.accessibilityIdentifier("editSelectedSongs")
            Button("Añadir a lista", systemImage: "music.note.list") { addToPlaylist = true }
            Menu("Más", systemImage: "ellipsis") {
                Button("Reproducir a continuación") { player.enqueueSongs(selectedIDs, playNext: true) }
                Button("Añadir al final de la cola") { player.enqueueSongs(selectedIDs, playNext: false) }
                Button("Analizar volumen", systemImage: "waveform") {
                    volumeSelection = .init(tracks: selectedIDs.compactMap { library.state.songs[$0]?.audioTrack })
                }
            }
        }.buttonStyle(.bordered).disabled(selection.isEmpty)
    }
}

struct CollectionRows: View {
    let player: PlaybackController
    let songs: [CollectionSong]
    var body: some View {
        ForEach(songs) { song in
            CollectionSongRow(player: player, song: song, play: { player.playSongs(songs.map(\.id), startingAt: song.id) })
        }
    }
}

struct CollectionSongRow: View {
    let player: PlaybackController
    let song: CollectionSong
    var showActions = true
    var play: (() -> Void)? = nil
    @State private var action: SongActionRequest?
    var body: some View {
        HStack(spacing: 12) {
            if let play {
                Button(action: play) { information }.buttonStyle(.plain)
                    .accessibilityIdentifier("library-song:\(song.relativePath)")
            } else { information }
            if player.library.state.favorites.contains(song.id) { Image(systemName: "heart.fill").foregroundStyle(.secondary).accessibilityLabel("Favorita") }
            if showActions, let track = song.audioTrack {
                Menu { SongActions(player: player, track: track) { action = $0 } } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("Opciones de \(song.title)").accessibilityIdentifier("options-song:\(song.relativePath)")
            }
        }.foregroundStyle(.primary)
            .contextMenu {
                if showActions, let track = song.audioTrack { SongActions(player: player, track: track) { action = $0 } }
            }
            .sheet(item: $action) { SongActionSheet(player: player, request: $0) }
    }
    private var information: some View {
        HStack(spacing: 12) {
            CachedCollectionArtwork(library: player.library, song: song).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.body.weight(.medium)).lineLimit(2)
                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }.contentShape(Rectangle())
    }
}
