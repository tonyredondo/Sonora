import SonoraCore
import SwiftUI

struct LibrarySearchView: View {
    let player: PlaybackController
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme
    private var library: MusicLibrary { player.library }
    private func matches(_ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }
    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Busca en tu música", systemImage: "magnifyingglass", description: Text("Encuentra canciones, artistas, álbumes y listas de tu biblioteca."))
            } else {
                let artists = library.artists.filter { matches($0.title) }
                let albums = library.albums.filter { matches($0.title + " " + $0.subtitle) }
                let playlists = library.state.playlists.filter { matches($0.name) }
                let songs = library.allSongs.filter { $0.matches(query) }
                if !artists.isEmpty {
                    Section("Artistas") {
                        ForEach(artists) { artist in
                            NavigationLink { ArtistCollectionView(player: player, artist: artist) } label: { Label(artist.title, systemImage: "music.mic") }
                                .accessibilityIdentifier("search-artist:" + artist.id)
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("Álbumes") {
                        ForEach(albums) { album in
                            NavigationLink {
                                CollectionSongList(player: player, title: album.title, ids: album.songIDs, group: album, albumGroup: true)
                            } label: { VStack(alignment: .leading) { Text(album.title); Text(album.subtitle).font(.caption).foregroundStyle(.secondary) } }
                                .accessibilityIdentifier("search-album:" + album.id)
                        }
                    }
                }
                if !playlists.isEmpty {
                    Section("Listas") {
                        ForEach(playlists) { list in
                            NavigationLink(list.name) { CollectionSongList(player: player, title: list.name, ids: list.songIDs, playlistID: list.id) }
                        }
                    }
                }
                if !songs.isEmpty { Section("Canciones") { CollectionRows(player: player, songs: songs) } }
                if artists.isEmpty && albums.isEmpty && playlists.isEmpty && songs.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .navigationTitle("Buscar").searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Canciones, artistas, álbumes y listas")
        .scrollContentBackground(.hidden).background(PlayerTheme(scheme).background)
    }
}
