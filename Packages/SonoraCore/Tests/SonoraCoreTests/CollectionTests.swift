import XCTest
@testable import SonoraCore

final class CollectionTests: XCTestCase {
    func testCollectionGroupsPlaylistsFavoritesHistoryAndSearchSurviveEncoding() throws {
        var state = MusicCollection()
        state.sources = [CollectionSource(id: "one", name: "Local", bookmark: Data([1]))]
        let a = CollectionSong(sourceID: "one", relativePath: "a.flac", tags: [.title: "Canción 2", .artist: "Intérprete A", .album: "Sesiones", .albumArtist: "Varios", .discNumber: "1", .trackNumber: "2"])
        let b = CollectionSong(sourceID: "one", relativePath: "b.mp3", tags: [.title: "Canción 1", .artist: "Intérprete B", .album: "Sesiones", .albumArtist: "Varios", .discNumber: "1", .trackNumber: "1"])
        state.upsert([a, b]); state.toggleFavorite(a.id)
        let list = try XCTUnwrap(state.createPlaylist("  Favoritas  "))
        state.add([a.id, b.id, a.id, "missing"], to: list)
        XCTAssertEqual(state.playlists.first?.songIDs, [a.id, b.id])
        state.move(in: list, from: [0], to: 2)
        XCTAssertEqual(state.playlists.first?.songIDs, [b.id, a.id])
        XCTAssertEqual(state.groups(byAlbum: true).count, 1)
        XCTAssertEqual(state.groups(byAlbum: true).first?.songIDs, [b.id, a.id])
        XCTAssertEqual(state.groups(byAlbum: false).count, 2)
        XCTAssertTrue(a.matches("cancion interprete")); XCTAssertFalse(a.matches("cancion inexistente"))
        state.recordPlayed(a.id); state.recordPlayed(b.id); state.recordPlayed(a.id)
        XCTAssertEqual(state.history.map(\.songID), [a.id, b.id])
        XCTAssertEqual(state.favorites, [a.id])
        XCTAssertEqual(try JSONDecoder().decode(MusicCollection.self, from: JSONEncoder().encode(state)), state)
    }

    func testAppendAndPlayNextKeepCurrentAndDistinguishSameNamesAcrossSources() {
        let a = AudioTrack(relativePath: "01.mp3")!, b = AudioTrack(relativePath: "02.mp3")!
        let other = AudioTrack(relativePath: "01.mp3", sourceID: "other")!
        var queue = PlaybackQueue(); queue.replace(with: [a, b])
        queue.insert([other, other], afterCurrent: false)
        XCTAssertEqual(queue.tracks.map(\.id), [a.id, b.id, other.id])
        queue.insert([other], afterCurrent: true)
        XCTAssertEqual(queue.tracks.map(\.id), [a.id, other.id, b.id])
        XCTAssertEqual(queue.current?.id, a.id)
        XCTAssertNotEqual(a.id, other.id)
        XCTAssertEqual(try JSONDecoder().decode(AudioTrack.self, from: JSONEncoder().encode(other)), other)
    }
}
