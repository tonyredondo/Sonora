import CarPlay
import Observation
import SonoraCore
import UIKit

@MainActor final class CarPlayCoordinator: NSObject, CPNowPlayingTemplateObserver, CPSearchTemplateDelegate {
    enum Control { case favorite, shuffle, repeatMode, rate, audio }
    let rootTemplate: CPTabBarTemplate
    let player: PlaybackController
    let present: (CPTemplate) -> Void
    private let dismissAlert: () -> Void
    private let tabs: [CPListTemplate]
    private var pages: [WeakCarPlayPage] = []
    private var controls: [CPNowPlayingButton] = []
    private var active = false
    private var observationID = UUID()
    private var lastIssue: String?
    private var searchText = ""

    init(player: PlaybackController, present: @escaping (CPTemplate) -> Void, dismissAlert: @escaping () -> Void = {}) {
        self.player = player; self.present = present; self.dismissAlert = dismissAlert
        tabs = ["Biblioteca", "Listas", "Favoritos", "Cola"].map { CPListTemplate(title: $0, sections: []) }
        let icons = ["music.note.house", "music.note.list", "heart", "list.bullet"]
        for (index, tab) in tabs.enumerated() {
            tab.tabTitle = tab.title; tab.tabImage = UIImage(systemName: icons[index])
            tab.emptyViewTitleVariants = [index == 3 ? "Tu cola está vacía" : "Todavía no hay música"]
            tab.emptyViewSubtitleVariants = ["La biblioteca no contiene música disponible."]
        }
        rootTemplate = CPTabBarTemplate(templates: tabs)
        super.init()
        for (index, tab) in tabs.enumerated() {
            attach(tab, rows: { [weak self] in self?.rootRows(index) ?? [] },
                   featured: { [weak self] in index == 0 ? self?.albumHighlights() : nil })
        }
        refresh()
    }

    func start() {
        guard !active else { return }
        active = true; observationID = UUID()
        controls = [
            CPNowPlayingImageButton(image: UIImage(systemName: "heart")!) { [weak self] _ in self?.perform(.favorite) },
            CPNowPlayingShuffleButton { [weak self] _ in self?.perform(.shuffle) },
            CPNowPlayingRepeatButton { [weak self] _ in self?.perform(.repeatMode) },
            CPNowPlayingPlaybackRateButton { [weak self] _ in self?.perform(.rate) },
            CPNowPlayingImageButton(image: UIImage(systemName: "speaker.wave.2.fill")!) { [weak self] _ in self?.perform(.audio) }
        ]
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(controls)
        CPNowPlayingTemplate.shared.upNextTitle = "Cola"
        CPNowPlayingTemplate.shared.add(self)
        refresh(); observe()
    }

    func stop() {
        guard active else { return }
        active = false; observationID = UUID()
        CPNowPlayingTemplate.shared.remove(self)
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
        controls = []
    }

    func perform(_ control: Control) {
        guard active else { return }
        if control == .audio { showAudio(); return }
        guard let track = self.player.current, !self.player.isDeletingFiles else { return }
        switch control {
        case .favorite: self.player.toggleFavorite(track)
        case .shuffle: self.player.shuffle.toggle()
        case .repeatMode: self.player.cycleRepeatMode()
        case .rate: self.player.cyclePlaybackRate()
        case .audio: break
        }
        refresh()
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self, active else { return }
            present(list("Cola") { [weak self] in self?.queueRows() ?? [] })
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self, active else { return }
            present(list("Álbum y artista") { [weak self] in self?.currentCollectionRows() ?? [] })
        }
    }

    private func observe() {
        guard active else { return }
        let token = observationID
        withObservationTracking {
            _ = self.player.library.state; _ = self.player.library.allSongs; _ = self.player.library.albums; _ = self.player.library.artists
            _ = self.player.queue; _ = self.player.details; _ = self.player.isPlaying; _ = self.player.isLoading; _ = self.player.issue
            _ = self.player.shuffle; _ = self.player.repeatMode; _ = self.player.equalizer.playback; _ = self.player.equalizer.settings
            _ = self.player.transitionSettings; _ = self.player.listeningSettings; _ = self.player.sleepTimer
            _ = self.player.currentSongTools; _ = self.player.songAnalysisIssue; _ = self.player.isDeletingFiles
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.active, self.observationID == token else { return }
                self.refresh(); self.observe()
            }
        }
    }

    func list(_ title: String, rows: @escaping () -> [CarPlayRow]) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Sin canciones"]
        template.emptyViewSubtitleVariants = ["No hay contenido disponible en esta colección."]
        attach(template, rows: rows)
        return template
    }

    private func attach(_ template: CPListTemplate, rows: @escaping () -> [CarPlayRow],
                        featured: @escaping () -> CPListImageRowItem? = { nil }) {
        let page = CarPlayPage(template: template, rows: rows, featured: featured)
        template.userInfo = page
        pages.append(WeakCarPlayPage(value: page))
    }

    private func refresh() {
        pages.removeAll { $0.value == nil }
        pages.forEach { $0.value?.update() }
        tabs[2].emptyViewTitleVariants = ["Tus favoritos"]
        tabs[2].emptyViewSubtitleVariants = ["Marca canciones con el corazón del reproductor."]
        tabs[3].emptyViewTitleVariants = [self.player.isLoading ? "Preparando la cola…" : "Tu cola está vacía"]
        if active {
            let available = self.player.current != nil && !self.player.isDeletingFiles
            for (index, control) in controls.enumerated() { control.isEnabled = index == 4 || available }
            controls.first?.isSelected = self.player.current.map(self.player.isFavorite) ?? false
            CPNowPlayingTemplate.shared.isUpNextButtonEnabled = !self.player.queue.tracks.isEmpty
            CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = !currentCollectionRows().isEmpty
        }
        if active, let issue = self.player.issue, issue != lastIssue {
            lastIssue = issue
            let close = CPAlertAction(title: "Cerrar", style: .cancel) { [weak self] _ in
                self?.player.issue = nil; self?.dismissAlert()
            }
            present(CPAlertTemplate(titleVariants: [issue], actions: [close]))
        } else if self.player.issue == nil { lastIssue = nil }
    }

    private func rootRows(_ index: Int) -> [CarPlayRow] {
        switch index {
        case 0:
            var rows = [
                CarPlayRow(title: "Álbumes", symbol: "square.stack", disclosure: true) { [weak self] in self?.showGroups(albums: true) },
                CarPlayRow(title: "Artistas", symbol: "music.mic", disclosure: true) { [weak self] in self?.showGroups(albums: false) },
                CarPlayRow(title: "Carpetas", symbol: "folder", disclosure: true) { [weak self] in self?.showFolders() },
                CarPlayRow(title: "Canciones", symbol: "music.note", disclosure: true) { [weak self] in
                    self?.showSongs("Canciones", ids: { [weak self] in self?.player.library.allSongs.map(\.id) ?? [] })
                },
                CarPlayRow(title: "Escuchado recientemente", symbol: "clock", disclosure: true) { [weak self] in
                    self?.showSongs("Recientes", ids: { [weak self] in self?.player.library.state.history.map(\.songID) ?? [] })
                }
            ]
            // Audio apps may present CPSearchTemplate only on iOS 27 or later.
            // Earlier systems reserve this template for navigation entitlements.
            if #available(iOS 27, *) {
                rows.append(CarPlayRow(title: "Buscar", symbol: "magnifyingglass", disclosure: true) { [weak self] in self?.showSearch() })
            }
            return rows
        case 1:
            return self.player.library.state.playlists.map { playlist in
                CarPlayRow(title: playlist.name, subtitle: "\(playlist.songIDs.count) canciones", symbol: "music.note.list",
                           artwork: artwork(for: playlist.songIDs.first), disclosure: true) { [weak self] in
                    self?.showSongs(playlist.name, ids: { [weak self] in
                        self?.player.library.state.playlists.first { $0.id == playlist.id }?.songIDs ?? []
                    })
                }
            }
        case 2:
            let albums = self.player.library.albums.filter { self.player.library.state.favoriteAlbums.contains($0.id) }.map { groupRow($0, albums: true) }
            let artists = self.player.library.artists.filter { self.player.library.state.favoriteArtists.contains($0.id) }.map { groupRow($0, albums: false) }
            return albums + artists + songRows(self.player.library.allSongs.filter { self.player.library.state.favorites.contains($0.id) }.map(\.id))
        default: return queueRows()
        }
    }

    private func groupRow(_ group: CollectionGroup, albums: Bool) -> CarPlayRow {
        CarPlayRow(title: group.title, subtitle: group.subtitle, symbol: albums ? "square.stack" : "music.mic",
                   artwork: artwork(for: group.songIDs.first), disclosure: true) { [weak self] in
            self?.showSongs(group.title, ids: { [weak self] in
                guard let self else { return [] }
                return (albums ? self.player.library.albums : self.player.library.artists).first { $0.id == group.id }?.songIDs ?? []
            })
        }
    }

    private func showGroups(albums: Bool) {
        present(list(albums ? "Álbumes" : "Artistas") { [weak self] in
            guard let self else { return [] }
            return (albums ? self.player.library.albums : self.player.library.artists).map { self.groupRow($0, albums: albums) }
        })
    }

    private func albumHighlights() -> CPListImageRowItem? {
        let groups = Array(self.player.library.albums.prefix(min(5, CPMaximumNumberOfGridImages)))
        guard !groups.isEmpty else { return nil }
        let images = groups.map { artwork(for: $0.songIDs.first)() ?? Self.placeholderArtwork }
        let row: CPListImageRowItem
        if #available(iOS 17.4, *) {
            row = CPListImageRowItem(text: "Tus álbumes", images: images, imageTitles: groups.map(\.title))
        } else { row = CPListImageRowItem(text: "Tus álbumes", images: images) }
        row.handler = { [weak self] _, done in self?.showGroups(albums: true); done() }
        row.listImageRowHandler = { [weak self] _, index, done in
            defer { done() }
            guard let self, groups.indices.contains(index) else { return }
            groupRow(groups[index], albums: true).action()
        }
        return row
    }

    private static let placeholderArtwork: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        return renderer.image { context in
            UIColor(red: 0.055, green: 0.063, blue: 0.067, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            UIImage(systemName: "waveform")?.withTintColor(UIColor(red: 0.96, green: 0.72, blue: 0.41, alpha: 1), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 20, y: 20, width: 40, height: 40))
        }
    }()

    func artwork(for id: String?) -> () -> UIImage? {
        let key = id.flatMap { self.player.library.state.songs[$0]?.artworkKey }
        let url = key.map { self.player.library.artworkDirectory.appendingPathComponent($0) }
        return {
            guard let url else { return nil }
            // Library artwork is already bounded to 400 pixels. Let each native
            // template size it for its display instead of upscaling a tiny icon.
            return UIImage(contentsOfFile: url.path)
        }
    }

    private func showFolders() {
        present(list("Carpetas") { [weak self] in
            guard let self else { return [] }
            return self.player.library.state.sources.map { source in
                CarPlayRow(title: source.name, symbol: "folder", disclosure: true) { [weak self] in
                    self?.showSongs(source.name, ids: { [weak self] in
                        self?.player.library.allSongs.filter { $0.sourceID == source.id }.sorted { a, b in
                            if a.relativePath == b.relativePath { return (a.cue?.number ?? 0) < (b.cue?.number ?? 0) }
                            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
                        }.map(\.id) ?? []
                    })
                }
            }
        })
    }

    private func showSongs(_ title: String, ids: @escaping () -> [String]) {
        let template = list(title) { [weak self] in
            guard let self else { return [] }
            let songs = ids().filter { self.player.library.state.songs[$0] != nil }
            guard !songs.isEmpty else { return [] }
            return [CarPlayRow(title: "Reproducir todo", symbol: "play.fill") { [weak self] in
                        self?.player.shuffle = false; self?.play(songs, selected: nil)
                    },
                    CarPlayRow(title: "Reproducir aleatoriamente", symbol: "shuffle") { [weak self] in
                        guard let self else { return }; self.player.shuffle = true; play(songs, selected: songs.randomElement())
                    }] + songRows(songs)
        }
        template.trailingNavigationBarButtons = [CPBarButton(image: UIImage(systemName: "text.badge.plus")!) { [weak self] _ in
            self?.showQueueActions(title: title, ids: ids)
        }]
        present(template)
    }

    func showQueueActions(title: String, ids: @escaping () -> [String]) {
        present(list(title) { [weak self] in
            guard let self else { return [] }
            let available = !ids().isEmpty && !self.player.isDeletingFiles
            return [
                CarPlayRow(title: "Reproducir después", symbol: "text.line.first.and.arrowtriangle.forward", enabled: available) { [weak self] in self?.enqueue(ids(), next: true) },
                CarPlayRow(title: "Añadir al final", symbol: "text.append", enabled: available) { [weak self] in self?.enqueue(ids(), next: false) }
            ]
        })
    }

    private func enqueue(_ ids: [String], next: Bool) {
        player.enqueueSongs(ids, playNext: next)
        present(list("Cola") { [weak self] in self?.queueRows() ?? [] })
    }

    private func songRows(_ ids: [String], limit: Int? = nil) -> [CarPlayRow] {
        ids.prefix(limit ?? ids.count).compactMap { id in
            guard let song = self.player.library.state.songs[id] else { return nil }
            return CarPlayRow(title: song.title, subtitle: song.artist, artwork: artwork(for: id),
                              playing: self.player.isPlaying && self.player.current.flatMap(self.player.libraryID) == id,
                              enabled: !self.player.isDeletingFiles) { [weak self] in self?.play(ids, selected: id) }
        }
    }

    private func play(_ ids: [String], selected: String?) {
        self.player.playSongs(ids, startingAt: selected)
        present(CPNowPlayingTemplate.shared)
    }

    private func queueRows() -> [CarPlayRow] {
        self.player.queue.tracks.map { track in
            let details = self.player.details[track.id]
            let id = self.player.libraryID(for: track)
            let song = id.flatMap { self.player.library.state.songs[$0] }
            let cached = artwork(for: id)
            return CarPlayRow(title: details?.title ?? song?.title ?? track.displayName, subtitle: details?.artist ?? song?.artist,
                              artwork: { details?.artwork ?? cached() }, playing: self.player.isPlaying && self.player.current?.id == track.id,
                              enabled: !self.player.isDeletingFiles) { [weak self] in
                guard let self, let index = self.player.queue.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                self.player.play(index: index); present(CPNowPlayingTemplate.shared)
            }
        }
    }

    private func currentCollectionRows() -> [CarPlayRow] {
        guard let track = self.player.current, let id = self.player.libraryID(for: track), let song = self.player.library.state.songs[id] else { return [] }
        var rows: [CarPlayRow] = []
        if let album = self.player.library.albums.first(where: { $0.id == song.albumID }) { rows.append(groupRow(album, albums: true)) }
        if let artist = self.player.library.artists.first(where: { $0.id == song.artistID }) { rows.append(groupRow(artist, albums: false)) }
        return rows
    }

    @available(iOS 27, *)
    private func showSearch() {
        searchText = ""
        let template = CPSearchTemplate()
        template.delegate = self
        present(template)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = searchIDs()
        completionHandler(songRows(ids, limit: 50).map { $0.item() })
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        if let handler = item.handler { handler(item, completionHandler) }
        else { completionHandler() }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        showSongs("Resultados", ids: { [weak self] in self?.searchIDs() ?? [] })
    }

    private func searchIDs() -> [String] {
        guard !searchText.isEmpty else { return self.player.library.state.history.map(\.songID) }
        return self.player.library.allSongs.filter { $0.matches(searchText) }.map(\.id)
    }
}
