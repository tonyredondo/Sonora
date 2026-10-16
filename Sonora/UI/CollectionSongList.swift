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
    @State private var newPlaylist = false
    @State private var exporting: PlaylistExportSelection?
    private var library: MusicLibrary { player.library }
    private var activeIDs: [String] { playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.songIDs } ?? ids }
    private var songs: [CollectionSong] { activeIDs.compactMap { library.state.songs[$0] }.filter { $0.matches(query) } }
    var body: some View {
        List(selection: $selection) {
            if !songs.isEmpty && !editMode.isEditing {
                Section {
                    Button("Reproducir", systemImage: "play.fill") { player.playSongs(songs.map(\.id)) }
                    Button("Añadir a la cola", systemImage: "text.badge.plus") { player.enqueueSongs(songs.map(\.id), playNext: false) }
                    if let playlistID { Button("Exportar playlist", systemImage: "square.and.arrow.up") { exporting = .init(id: playlistID, name: title) } }
                    Button(albumGroup ? "Analizar álbum completo" : "Analizar volumen", systemImage: "waveform") {
                        let tracks = (albumGroup ? activeIDs : songs.map(\.id)).compactMap { library.state.songs[$0]?.audioTrack }
                        volumeSelection = .init(tracks: tracks, album: albumGroup)
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
        .navigationTitle(playlistID.flatMap { id in library.state.playlists.first { $0.id == id }?.name } ?? title)
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
            if sourceID != nil { ToolbarItem(placement: .primaryAction) { Button("Olvidar carpeta", role: .destructive) { forget = true } } }
            if editMode.isEditing {
                ToolbarItem(placement: .bottomBar) { Button("Seleccionar todo") { selection = Set(songs.map(\.id)) } }
                ToolbarItem(placement: .bottomBar) {
                    Menu("\(selection.count) seleccionadas") {
                        Button("Reproducir a continuación") { player.enqueueSongs(activeIDs.filter { selection.contains($0) }, playNext: true) }
                        Button("Añadir al final de la cola") { player.enqueueSongs(activeIDs.filter { selection.contains($0) }, playNext: false) }
                        Menu("Añadir a playlist") {
                            ForEach(library.state.playlists) { list in Button(list.name) { library.add(activeIDs.filter { selection.contains($0) }, to: list.id) } }
                            Button("Nueva playlist…") { newPlaylist = true }
                        }
                        Button("Editar información", systemImage: "pencil") {
                            let tracks = activeIDs.filter { selection.contains($0) }.compactMap { library.state.songs[$0]?.audioTrack }
                            if !tracks.isEmpty { metadataSelection = MetadataSelection(tracks: tracks) }
                        }
                        Button("Analizar volumen", systemImage: "waveform") {
                            volumeSelection = .init(tracks: activeIDs.filter { selection.contains($0) }.compactMap { library.state.songs[$0]?.audioTrack })
                        }
                    }.disabled(selection.isEmpty)
                }
            }
        }
        .sheet(item: $metadataSelection) { selected in
            if selected.tracks.count == 1, let track = selected.tracks.first { MetadataEditorView(player: player, track: track) }
            else { BulkMetadataEditorView(player: player, tracks: selected.tracks) }
        }
        .sheet(item: $exporting) { PlaylistExportView(player: player, playlist: $0) }
        .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
        .confirmationDialog("¿Olvidar esta carpeta?", isPresented: $forget, titleVisibility: .visible) {
            Button("Olvidar carpeta", role: .destructive) { if let sourceID { player.forgetSource(sourceID); dismiss() } }
        } message: { Text("Se quitarán sus referencias de la biblioteca, las playlists y la cola. Los archivos originales no se borrarán.") }
        .sheet(isPresented: $newPlaylist) {
            PlaylistNameEditor(initialName: "", renaming: false) { name in
                if let id = library.createPlaylist(name) { library.add(activeIDs.filter { selection.contains($0) }, to: id) }
            }
        }
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
    @State private var editing = false
    @State private var creating = false
    @State private var volumeSelection: VolumeAnalysisSelection?
    var body: some View {
        HStack(spacing: 12) {
            if let play {
                Button(action: play) { information }.buttonStyle(.plain)
                    .accessibilityIdentifier("library-song:\(song.relativePath)")
            } else { information }
            if player.library.state.favorites.contains(song.id) { Image(systemName: "heart.fill").foregroundStyle(.secondary).accessibilityLabel("Favorita") }
            if showActions {
                CollectionSongMenu(player: player, song: song, edit: { editing = true }, create: { creating = true },
                                   analyze: { if let track = song.audioTrack { volumeSelection = .init(tracks: [track]) } })
            }
        }.foregroundStyle(.primary)
            .contextMenu {
                if showActions {
                    CollectionSongActions(player: player, song: song, analyze: { if let track = song.audioTrack { volumeSelection = .init(tracks: [track]) } })
                }
            }
            .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
            .sheet(isPresented: $editing) { if let track = song.audioTrack { MetadataEditorView(player: player, track: track) } }
            .sheet(isPresented: $creating) {
                PlaylistNameEditor(initialName: "", renaming: false) { name in
                    if let id = player.library.createPlaylist(name) { player.library.add([song.id], to: id) }
                }
            }
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

struct CollectionSongMenu: View {
    let player: PlaybackController
    let song: CollectionSong
    let edit: () -> Void
    let create: () -> Void
    let analyze: () -> Void
    var body: some View {
        Menu {
            CollectionSongActions(player: player, song: song, analyze: analyze)
            Button("Editar información", systemImage: "info.circle", action: edit)
            Button("Nueva playlist con esta canción…", action: create)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Opciones de \(song.title)")
            .accessibilityIdentifier("options-song:\(song.relativePath)")
    }
}

struct CollectionSongActions: View {
    let player: PlaybackController
    let song: CollectionSong
    var analyze: (() -> Void)? = nil
    var body: some View {
        Button("Reproducir a continuación", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueueSongs([song.id], playNext: true) }
        Button("Añadir al final de la cola", systemImage: "text.badge.plus") { player.enqueueSongs([song.id], playNext: false) }
        Button(player.library.state.favorites.contains(song.id) ? "Quitar de favoritos" : "Marcar como favorita", systemImage: "heart") { player.library.toggleFavorite(song.id) }
        Menu("Añadir a playlist") {
            ForEach(player.library.state.playlists) { list in Button(list.name) { player.library.add([song.id], to: list.id) } }
            if player.library.state.playlists.isEmpty { Text("Crea una playlist desde la biblioteca o las opciones de la canción.") }
        }
        if let analyze {
            Button("Analizar volumen", systemImage: "waveform", action: analyze)
                .accessibilityIdentifier("analyze-song:" + song.relativePath)
        }
    }
}
