import SonoraCore
import SwiftUI

/// A request keeps the selected track stable if playback advances while a sheet is open.
struct SongActionRequest: Identifiable {
    enum Action { case information, lyrics, playlist, volume, album, artist, files }
    let id = UUID()
    let track: AudioTrack
    let action: Action
    @MainActor init(player: PlaybackController, track: AudioTrack, action: Action) {
        self.track = player.pinnedTrack(track); self.action = action
    }
}

struct SongActions: View {
    let player: PlaybackController
    let track: AudioTrack
    let open: (SongActionRequest) -> Void
    private var song: CollectionSong? { player.libraryID(for: track).flatMap { player.library.state.songs[$0] } }

    var body: some View {
        Button("Reproducir a continuación", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(track, playNext: true) }
        Button("Añadir al final de la cola", systemImage: "text.badge.plus") { player.enqueue(track, playNext: false) }
        if song != nil {
            Button("Añadir a lista", systemImage: "music.note.list") { select(.playlist) }
            Button(player.isFavorite(track) ? "Quitar de favoritos" : "Marcar como favorita", systemImage: "heart") { player.toggleFavorite(track) }
        }
        Divider()
        Button("Letra", systemImage: "quote.bubble") { select(.lyrics) }
        Button("Editar información", systemImage: "pencil") { select(.information) }
        if let song {
            if player.library.albums.contains(where: { $0.id == song.albumID }) {
                Button("Ir al álbum", systemImage: "square.stack") { select(.album) }
            }
            if player.library.artists.contains(where: { $0.id == song.artistID }) {
                Button("Ir al artista", systemImage: "music.mic") { select(.artist) }
            }
            Button("Ver archivos de la fuente", systemImage: "folder") { select(.files) }
        }
        Divider()
        Button("Analizar volumen", systemImage: "waveform") { select(.volume) }
            .accessibilityIdentifier("analyze-song:" + track.relativePath)
    }
    private func select(_ action: SongActionRequest.Action) { open(.init(player: player, track: track, action: action)) }
}

struct SongActionSheet: View {
    let player: PlaybackController
    let request: SongActionRequest
    @Environment(\.dismiss) private var dismiss
    private var song: CollectionSong? { player.libraryID(for: request.track).flatMap { player.library.state.songs[$0] } }

    var body: some View {
        switch request.action {
        case .information: MetadataEditorView(player: player, track: request.track)
        case .lyrics: LyricsView(player: player, track: request.track)
        case .volume: VolumeAnalysisView(player: player, selection: .init(tracks: [request.track]))
        case .playlist: AddSongsToPlaylistView(player: player, songIDs: song.map { [$0.id] } ?? [])
        case .album, .artist, .files:
            NavigationStack {
                Group {
                    if let song {
                        switch request.action {
                        case .album:
                            if let album = player.library.albums.first(where: { $0.id == song.albumID }) {
                                CollectionSongList(player: player, title: album.title, ids: album.songIDs, group: album, albumGroup: true)
                            }
                        case .artist:
                            if let artist = player.library.artists.first(where: { $0.id == song.artistID }) { ArtistCollectionView(player: player, artist: artist) }
                        case .files: SourceFolderView(player: player, sourceID: song.sourceID)
                        default: EmptyView()
                        }
                    } else { ContentUnavailableView("Canción no disponible", systemImage: "music.note", description: Text("Su fuente ya no está en la biblioteca.")) }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            }
        }
    }
}

struct AddSongsToPlaylistView: View {
    let player: PlaybackController
    let songIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Nueva lista", systemImage: "plus") { creating = true }
                }
                Section("Tus listas") {
                    ForEach(player.library.state.playlists) { list in
                        Button { player.library.add(songIDs, to: list.id); dismiss() } label: {
                            Label(list.name, systemImage: "music.note.list").frame(minHeight: 44)
                        }
                    }
                    if player.library.state.playlists.isEmpty { Text("Crea una lista para guardar estas canciones.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Añadir a lista").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .sheet(isPresented: $creating) {
                PlaylistNameEditor(initialName: "", renaming: false) { name in
                    if let id = player.library.createPlaylist(name) { player.library.add(songIDs, to: id); dismiss() }
                }
            }
        }
    }
}
