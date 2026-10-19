import SonoraCore
import SwiftUI

struct LibrarySearchView: View {
    let player: PlaybackController
    @State private var query = ""
    @State private var scope = Scope.all
    private enum Scope: String, CaseIterable {
        case all = "Todo", songs = "Canciones", albums = "Álbumes", artists = "Artistas", playlists = "Listas"
    }
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
                let artists = library.artists.filter { (scope == .all || scope == .artists) && matches($0.title) }
                let albums = library.albums.filter { (scope == .all || scope == .albums) && matches($0.title + " " + $0.subtitle) }
                let playlists = library.state.playlists.filter { (scope == .all || scope == .playlists) && matches($0.name) }
                let songs = library.allSongs.filter { (scope == .all || scope == .songs) && $0.matches(query) }
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
        .miniPlayerContentMargins()
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Scope.allCases, id: \.self) { value in
                        Button { scope = value } label: {
                            Text(value.rawValue).font(.subheadline.weight(scope == value ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(scope == value ? PlayerTheme(scheme).accent.opacity(0.2) : Color.clear, in: .capsule)
                        }.buttonStyle(.plain).accessibilityAddTraits(scope == value ? [.isSelected] : [])
                            .accessibilityIdentifier("searchScope-" + value.rawValue)
                    }
                }.padding(.horizontal).padding(.vertical, 4)
            }.background(PlayerTheme(scheme).background)
        }
        .navigationTitle("Buscar").searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Canciones, artistas, álbumes y listas")
        .scrollContentBackground(.hidden).background(PlayerTheme(scheme).background)
    }
}
