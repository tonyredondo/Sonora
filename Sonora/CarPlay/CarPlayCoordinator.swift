import CarPlay
import Observation
import SonoraCore
import UIKit

@MainActor private struct CarPlayRow {
    let title: String
    var subtitle: String? = nil
    var symbol = "music.note"
    var playing = false
    let action: () -> Void
}

/// Pages update in place, so a large collection never exceeds CarPlay's stack
/// depth or silently loses the rows after a framework item limit.
@MainActor private final class CarPlayPage {
    weak var template: CPListTemplate?
    private var rows: [CarPlayRow]
    private var offset = 0
    private let pageSize = max(1, min(98, Int(CPListTemplate.maximumItemCount) - 2))
    init(template: CPListTemplate, rows: [CarPlayRow]) { self.template = template; self.rows = rows; update() }
    func replace(_ values: [CarPlayRow]) { rows = values; offset = min(offset, max(0, values.count - 1) / pageSize * pageSize); update() }
    private func update() {
        var items: [CPListItem] = []
        if offset > 0 {
            let item = CPListItem(text: "Anterior", detailText: nil, image: UIImage(systemName: "chevron.left"))
            item.handler = { [weak self] _, done in self?.offset -= self?.pageSize ?? 0; self?.update(); done() }; items.append(item)
        }
        for row in rows.dropFirst(offset).prefix(pageSize) {
            let item = CPListItem(text: row.title, detailText: row.subtitle, image: UIImage(systemName: row.symbol))
            item.isPlaying = row.playing
            item.handler = { _, done in row.action(); done() }; items.append(item)
        }
        if offset + pageSize < rows.count {
            let item = CPListItem(text: "Más", detailText: "\(offset + pageSize) de \(rows.count)", image: UIImage(systemName: "chevron.right"))
            item.handler = { [weak self] _, done in self?.offset += self?.pageSize ?? 0; self?.update(); done() }; items.append(item)
        }
        template?.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }
}

@MainActor final class CarPlayCoordinator: NSObject, CPNowPlayingTemplateObserver {
    let rootTemplate: CPTabBarTemplate
    private let player: PlaybackController
    private let present: (CPTemplate) -> Void
    private let dismissAlert: () -> Void
    private let tabs: [CPListTemplate]
    private var active = false
    private var observationID = UUID()
    private var lastIssue: String?
    init(player: PlaybackController, present: @escaping (CPTemplate) -> Void, dismissAlert: @escaping () -> Void = {}) {
        self.player = player; self.present = present; self.dismissAlert = dismissAlert
        tabs = ["Biblioteca", "Playlists", "Favoritos", "Cola"].map { CPListTemplate(title: $0, sections: []) }
        let icons = ["music.note.house", "music.note.list", "heart", "text.line.first.and.arrowtriangle.forward"]
        for (index, tab) in tabs.enumerated() {
            tab.tabTitle = tab.title; tab.tabImage = UIImage(systemName: icons[index])
            tab.emptyViewTitleVariants = [index == 3 ? "Tu cola está vacía" : "Todavía no hay música"]
            tab.emptyViewSubtitleVariants = ["Añade música desde Sonora en el iPhone."]
        }
        rootTemplate = CPTabBarTemplate(templates: tabs)
        super.init()
        refresh()
    }
    func start() {
        guard !active else { return }; active = true; observationID = UUID()
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        CPNowPlayingTemplate.shared.upNextTitle = "Cola"
        CPNowPlayingTemplate.shared.add(self)
        refresh(); observe()
    }
    func stop() { active = false; observationID = UUID(); CPNowPlayingTemplate.shared.remove(self) }
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in guard let self, self.active else { return }; self.present(self.list("Cola", rows: self.queueRows())) }
    }
    private func observe() {
        guard active else { return }
        let token = observationID
        withObservationTracking {
            _ = player.library.state; _ = player.library.allSongs; _ = player.library.albums; _ = player.library.artists
            _ = player.queue; _ = player.details; _ = player.isPlaying
            _ = player.issue
            _ = player.isLoading
        } onChange: { [weak self] in
            Task { @MainActor in guard let self, self.active, self.observationID == token else { return }; self.refresh(); self.observe() }
        }
    }
    private func list(_ title: String, rows: [CarPlayRow]) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Sin canciones"]
        template.emptyViewSubtitleVariants = ["Revisa la biblioteca en el iPhone."]
        template.userInfo = CarPlayPage(template: template, rows: rows)
        return template
    }
    private func replace(_ index: Int, rows: [CarPlayRow]) {
        if let page = tabs[index].userInfo as? CarPlayPage { page.replace(rows) }
        else { tabs[index].userInfo = CarPlayPage(template: tabs[index], rows: rows) }
    }
    private func refresh() {
        replace(0, rows: [
            CarPlayRow(title: "Álbumes", symbol: "square.stack", action: { [weak self] in self?.showGroups(albums: true) }),
            CarPlayRow(title: "Artistas", symbol: "music.mic", action: { [weak self] in self?.showGroups(albums: false) }),
            CarPlayRow(title: "Carpetas", symbol: "folder", action: { [weak self] in self?.showFolders() }),
            CarPlayRow(title: "Canciones", action: { [weak self] in guard let self else { return }; showSongs("Canciones", ids: player.library.allSongs.map(\.id)) })
        ])
        replace(1, rows: player.library.state.playlists.map { playlist in
            CarPlayRow(title: playlist.name, subtitle: "\(playlist.songIDs.count) canciones", symbol: "music.note.list", action: { [weak self] in self?.showSongs(playlist.name, ids: playlist.songIDs) })
        })
        let favoriteAlbums = player.library.albums.filter { player.library.state.favoriteAlbums.contains($0.id) }.map { group in
            CarPlayRow(title: group.title, subtitle: "Álbum · " + group.subtitle, symbol: "square.stack", action: { [weak self] in self?.showSongs(group.title, ids: group.songIDs) })
        }
        let favoriteArtists = player.library.artists.filter { player.library.state.favoriteArtists.contains($0.id) }.map { group in
            CarPlayRow(title: group.title, subtitle: "Artista", symbol: "music.mic", action: { [weak self] in self?.showSongs(group.title, ids: group.songIDs) })
        }
        replace(2, rows: favoriteAlbums + favoriteArtists + songRows(player.library.allSongs.filter { player.library.state.favorites.contains($0.id) }.map(\.id)))
        tabs[2].emptyViewTitleVariants = ["Tus favoritos"]
        tabs[2].emptyViewSubtitleVariants = ["Marca canciones, álbumes o artistas en el iPhone."]
        replace(3, rows: queueRows())
        tabs[3].emptyViewTitleVariants = [player.isLoading ? "Preparando la cola…" : "Tu cola está vacía"]
        if active, let issue = player.issue, issue != lastIssue {
            lastIssue = issue
            let close = CPAlertAction(title: "Cerrar", style: .cancel) { [weak self] _ in
                self?.player.issue = nil; self?.dismissAlert()
            }
            present(CPAlertTemplate(titleVariants: [issue], actions: [close]))
        } else if player.issue == nil { lastIssue = nil }
    }
    private func showGroups(albums: Bool) {
        let groups = albums ? player.library.albums : player.library.artists
        present(list(albums ? "Álbumes" : "Artistas", rows: groups.map { group in
            CarPlayRow(title: group.title, subtitle: group.subtitle, symbol: albums ? "square.stack" : "music.mic", action: { [weak self] in self?.showSongs(group.title, ids: group.songIDs) })
        }))
    }
    private func showFolders() {
        present(list("Carpetas", rows: player.library.state.sources.map { source in
            CarPlayRow(title: source.name, symbol: "folder", action: { [weak self] in
                guard let self else { return }
                let songs = player.library.allSongs.filter { $0.sourceID == source.id }.sorted { a, b in
                    if a.relativePath == b.relativePath { return (a.cue?.number ?? 0) < (b.cue?.number ?? 0) }
                    return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
                }
                showSongs(source.name, ids: songs.map(\.id))
            })
        }))
    }
    private func showSongs(_ title: String, ids: [String]) {
        let all = ids.isEmpty ? [] : [CarPlayRow(title: "Reproducir todo", symbol: "play.fill", action: { [weak self] in self?.play(ids, selected: nil) })]
        present(list(title, rows: all + songRows(ids)))
    }
    private func songRows(_ ids: [String]) -> [CarPlayRow] {
        ids.compactMap { id in
            guard let song = player.library.state.songs[id] else { return nil }
            return CarPlayRow(title: song.title, subtitle: song.artist, playing: player.isPlaying && player.current.flatMap(player.libraryID) == id,
                              action: { [weak self] in self?.play(ids, selected: id) })
        }
    }
    private func play(_ ids: [String], selected: String?) { player.playSongs(ids, startingAt: selected); present(CPNowPlayingTemplate.shared) }
    private func queueRows() -> [CarPlayRow] {
        player.queue.tracks.enumerated().map { index, track in
            let details = player.details[track.id]
            return CarPlayRow(title: details?.title ?? track.displayName, subtitle: details?.artist, playing: player.isPlaying && player.current?.id == track.id,
                              action: { [weak self] in self?.player.play(index: index); self?.present(CPNowPlayingTemplate.shared) })
        }
    }
}
