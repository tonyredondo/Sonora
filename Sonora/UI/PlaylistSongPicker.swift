import SonoraCore
import SwiftUI

struct PlaylistSongPicker: View {
    let player: PlaybackController
    let playlistID: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Set<String> = []
    private var playlist: MusicPlaylist? { player.library.state.playlists.first { $0.id == playlistID } }
    private var existing: Set<String> { Set(playlist?.songIDs ?? []) }
    private var songs: [CollectionSong] { player.library.allSongs.filter { $0.matches(query) } }
    private var selectedIDs: [String] { player.library.allSongs.filter { selection.contains($0.id) && !existing.contains($0.id) }.map(\.id) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(playlist?.name ?? "Lista eliminada").font(.headline)
                    Button("Seleccionar resultados") { selection.formUnion(songs.map(\.id).filter { !existing.contains($0) }) }
                        .disabled(songs.allSatisfy { existing.contains($0.id) })
                }
                ForEach(songs) { song in
                    Button {
                        if !selection.insert(song.id).inserted { selection.remove(song.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: existing.contains(song.id) || selection.contains(song.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).foregroundStyle(.primary)
                                Text(existing.contains(song.id) ? "Ya está en la lista" : song.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.frame(minHeight: 44).contentShape(.rect)
                    }.buttonStyle(.plain).disabled(existing.contains(song.id))
                        .accessibilityValue(selection.contains(song.id) ? "Seleccionada" : "")
                        .accessibilityIdentifier("playlist-pick-\(song.relativePath)")
                }
                if songs.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Cancelar") { dismiss() }.buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("cancelPlaylistSongs")
                    Button { player.library.add(selectedIDs, to: playlistID); dismiss() } label: {
                        Text("Añadir (\(selectedIDs.count))").frame(maxWidth: .infinity, minHeight: 32)
                    }.buttonStyle(.borderedProminent).foregroundStyle(scheme == .dark ? Color.black : Color.white)
                        .disabled(selectedIDs.isEmpty || playlist == nil).accessibilityIdentifier("confirmPlaylistSongs")
                }.padding().background(.bar)
            }
            .searchable(text: $query, prompt: "Canción, artista o álbum")
            .navigationTitle("Añadir canciones").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PlaylistSongSelection: Identifiable { let id: String }

func songCount(_ count: Int) -> String { count == 1 ? "1 canción" : "\(count) canciones" }
