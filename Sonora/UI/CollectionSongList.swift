import SonoraCore
import SwiftUI

private struct MetadataSelection: Identifiable {
    let id = UUID()
    let tracks: [AudioTrack]
    var context: BulkMetadataContext = .selection
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
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var metadataSelection: MetadataSelection?
    @State private var volumeSelection: VolumeAnalysisSelection?
    @State private var forget = false
    @State private var addToPlaylist = false
    @State private var pickingSongs = false
    @State private var renaming = false
    @State private var deletingPlaylist = false
    @State private var exporting: PlaylistExportSelection?
    @State private var browsingFiles = false
    private var library: MusicLibrary { player.library }
    private var firstSong: CollectionSong? { activeIDs.first.flatMap { library.state.songs[$0] } }
    private var displayedTitle: String { playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.name } ?? (albumGroup ? firstSong?.album ?? title : title) }
    private var activeIDs: [String] { playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.songIDs } ?? ids }
    private var songs: [CollectionSong] { activeIDs.compactMap { library.state.songs[$0] }.filter { $0.matches(query) } }
    var body: some View {
        List(selection: $selection) {
            if albumGroup, let group, !editMode.isEditing {
                Section {
                    HStack(spacing: 16) {
                        CachedCollectionArtwork(library: library, song: activeIDs.first.flatMap { library.state.songs[$0] })
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(firstSong?.albumArtist ?? group.subtitle).font(.headline)
                            Text(songCount(activeIDs.count)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
            if !editMode.isEditing {
                Section {
                    if playlistID != nil {
                        playlistActions
                    } else if !songs.isEmpty || sourceID != nil {
                        collectionActions
                    }
                }.compactActionListRow()
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
            if songs.isEmpty { ContentUnavailableView("Sin canciones", systemImage: "music.note", description: Text(query.isEmpty ? (playlistID != nil ? "Pulsa + para elegir música de tu biblioteca." : "Esta colección todavía no tiene canciones.") : "No hay resultados para esta búsqueda.")) }
            if editMode.isEditing { Text("Selecciona canciones para añadirlas a una playlist, ponerlas en cola o editar su información en conjunto.").font(.footnote).foregroundStyle(.secondary) }
        }
        .compactContentSpacing()
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
                    CompactActionRow { selectionActions }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .background(PlayerTheme(scheme).background)
            }
        }
        .sheet(item: $metadataSelection) { selected in
            if selected.tracks.count == 1, let track = selected.tracks.first, case .selection = selected.context { MetadataEditorView(player: player, track: track) }
            else { BulkMetadataEditorView(player: player, tracks: selected.tracks, context: selected.context) }
        }
        .sheet(isPresented: $pickingSongs) { if let playlistID { PlaylistSongPicker(player: player, playlistID: playlistID) } }
        .sheet(isPresented: $renaming) {
            PlaylistNameEditor(initialName: playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.name } ?? title, renaming: true) { name in
                if let playlistID { library.renamePlaylist(playlistID, name: name) }
            }
        }
        .confirmationDialog("¿Eliminar esta lista?", isPresented: $deletingPlaylist, titleVisibility: .visible) {
            Button("Eliminar playlist", role: .destructive) { if let playlistID { library.deletePlaylist(playlistID); dismiss() } }
        } message: { Text("Las canciones y los archivos se conservan en la biblioteca.") }
        .sheet(item: $exporting) { PlaylistExportView(player: player, playlist: $0) }
        .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
        .navigationDestination(isPresented: $browsingFiles) {
            if let sourceID { SourceFolderView(player: player, sourceID: sourceID) }
        }
        .confirmationDialog("¿Quitar esta fuente de la biblioteca?", isPresented: $forget, titleVisibility: .visible) {
            Button("Quitar de la biblioteca", role: .destructive) { if let sourceID { player.forgetSource(sourceID); dismiss() } }
        } message: { Text("Se quitarán sus referencias de la biblioteca, las playlists y la cola. Los archivos originales no se borrarán.") }
        .sheet(isPresented: $addToPlaylist) { AddSongsToPlaylistView(player: player, songIDs: selectedIDs) }
    }
    private var playbackActions: some View {
        Group {
            Button { playSongs(shuffled: false) } label: { CompactActionLabel(title: "Reproducir", icon: "play.fill", prominent: true) }
            Button { playSongs(shuffled: true) } label: { CompactActionLabel(title: "Aleatorio", icon: "shuffle") }
        }
    }
    private var collectionActions: some View {
        CompactActionRow(layout: songs.isEmpty ? .inline : .icons) {
            if !songs.isEmpty { playbackActions }
            if albumGroup, !songs.isEmpty {
                Button {
                    metadataSelection = MetadataSelection(tracks: activeIDs.compactMap { library.state.songs[$0]?.audioTrack }, context: .album(displayedTitle))
                } label: { CompactActionLabel(title: "Editar álbum", icon: "pencil", caption: "Editar") }
                    .accessibilityIdentifier("editAlbum")
            }
            if sourceID != nil {
                Button { browsingFiles = true } label: { CompactActionLabel(title: "Explorar archivos", icon: "folder", caption: "Archivos") }
                    .accessibilityIdentifier("browseSourceFiles")
            }
            if !songs.isEmpty {
                Menu { collectionMenuActions } label: { CompactActionLabel(title: "Más", icon: "ellipsis") }
                    .accessibilityIdentifier("collectionOptions")
            }
        }
    }
    private var playlistActions: some View {
        CompactActionRow(layout: songs.isEmpty ? .inline : .icons) {
            if !songs.isEmpty { playbackActions }
            Button { pickingSongs = true } label: { CompactActionLabel(title: "Añadir canciones", icon: "plus", caption: "Añadir") }
                .accessibilityIdentifier("addPlaylistSongs")
            Menu {
                if !songs.isEmpty {
                    collectionMenuActions
                    Divider()
                }
                Button("Renombrar") { renaming = true }
                Button("Ordenar o quitar canciones") { editMode = .active }
                Button("Exportar playlist", systemImage: "square.and.arrow.up") {
                    if let playlistID { exporting = .init(id: playlistID, name: displayedTitle) }
                }
                Divider()
                Button("Eliminar playlist", role: .destructive) { deletingPlaylist = true }
            } label: { CompactActionLabel(title: "Gestionar lista", icon: "ellipsis", caption: "Más") }
                .accessibilityIdentifier("managePlaylist")
        }
    }
    private var collectionMenuActions: some View {
        Group {
            Button("Añadir a la cola", systemImage: "text.badge.plus") { player.enqueueSongs(songs.map(\.id), playNext: false) }
            Button(albumGroup ? "Analizar volumen del álbum" : "Analizar volumen", systemImage: "waveform") {
                let tracks = (albumGroup ? activeIDs : songs.map(\.id)).compactMap { library.state.songs[$0]?.audioTrack }
                volumeSelection = .init(tracks: tracks, album: albumGroup)
            }
        }
    }
    private func playSongs(shuffled: Bool) {
        player.shuffle = shuffled
        let ids = songs.map(\.id)
        player.playSongs(shuffled ? ids.shuffled() : ids)
    }
    private var selectedIDs: [String] { activeIDs.filter { selection.contains($0) } }
    private var selectionActions: some View {
        Group {
            Button {
                metadataSelection = MetadataSelection(tracks: selectedIDs.compactMap { library.state.songs[$0]?.audioTrack })
            } label: { CompactActionLabel(title: "Editar información", icon: "pencil", caption: "Editar") }
                .accessibilityIdentifier("editSelectedSongs")
            Button { addToPlaylist = true } label: { CompactActionLabel(title: "Añadir a lista", icon: "music.note.list", caption: "A lista") }
                .accessibilityIdentifier("addSelectedToPlaylist")
            Menu {
                Button("Reproducir a continuación") { player.enqueueSongs(selectedIDs, playNext: true) }
                Button("Añadir al final de la cola") { player.enqueueSongs(selectedIDs, playNext: false) }
                Button("Analizar volumen", systemImage: "waveform") {
                    volumeSelection = .init(tracks: selectedIDs.compactMap { library.state.songs[$0]?.audioTrack })
                }
            } label: { CompactActionLabel(title: "Más", icon: "ellipsis") }
                .accessibilityIdentifier("selectedSongsOptions")
        }.disabled(selection.isEmpty)
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
