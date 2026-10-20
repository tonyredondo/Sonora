import CarPlay
import AVFAudio
import MediaPlayer
import SonoraCore
import XCTest
@testable import Sonora

@MainActor final class CarPlayTests: XCTestCase {
    private func player() async throws -> (PlaybackController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<88200 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.05) } }
        try AVAudioFile(forWriting: root.appendingPathComponent("song.wav"), settings: format.settings).write(from: buffer)
        let defaults = UserDefaults(suiteName: "SonoraTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "prepareQueueTranslation")
        defaults.set(false, forKey: "prepareQueueMeaning")
        let player = PlaybackController(defaults: defaults)
        await player.loadFolder(root, autoPlay: false)
        return (player, root)
    }
    func testRealTemplatesExposeLibraryPlaylistsFavoritesAndQueueWithWorkingSelection() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        XCTAssertEqual(car.rootTemplate.templates.map(\.tabTitle), ["Biblioteca", "Listas", "Favoritos", "Cola"])
        let queue = try XCTUnwrap(car.rootTemplate.templates.last as? CPListTemplate)
        let row = try XCTUnwrap(queue.sections.first?.items.first as? CPListItem)
        var completed = false
        row.handler?(row, { completed = true })
        XCTAssertTrue(completed)
        XCTAssertTrue(shown.last === CPNowPlayingTemplate.shared)
        let deadline = Date().addingTimeInterval(3)
        while !player.isPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isPlaying); XCTAssertEqual(player.current?.relativePath, "song.wav")
    }
    func testRootUpdatesAfterFavoriteAndPlaylistChangesAndDisconnectStopsObservation() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        car.start()
        defer { car.stop() }
        let list = try XCTUnwrap(player.library.createPlaylist("Carretera"))
        let song = try XCTUnwrap(player.library.state.songs.keys.first)
        player.library.add([song], to: list); player.library.toggleFavorite(song)
        try await Task.sleep(for: .milliseconds(300))
        let playlists = try XCTUnwrap(car.rootTemplate.templates[1] as? CPListTemplate)
        XCTAssertEqual((playlists.sections.first?.items.first as? CPListItem)?.text, "Carretera")
        let favorites = try XCTUnwrap(car.rootTemplate.templates[2] as? CPListTemplate)
        XCTAssertFalse(favorites.sections.isEmpty)
        car.stop()
        _ = player.library.createPlaylist("Tras desconectar")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playlists.sections.first?.items.count, 1)
        car.start()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playlists.sections.first?.items.count, 2)
    }
    func testPaginationKeepsEveryPlaylistWithoutGrowingTheNavigationStack() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let names = (0..<205).map { "Lista \($0)" }
        for name in names { _ = player.library.createPlaylist(name) }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        let list = try XCTUnwrap(car.rootTemplate.templates[1] as? CPListTemplate)
        var observed: [String] = []
        for _ in 0..<4 {
            let items = list.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
            XCTAssertLessThanOrEqual(items.count, Int(CPListTemplate.maximumItemCount))
            observed.append(contentsOf: items.compactMap(\.text).filter { $0 != "Anterior" && $0 != "Más" })
            guard let next = items.first(where: { $0.text == "Más" }) else { break }
            next.handler?(next, {})
        }
        XCTAssertEqual(observed, names)
    }
    func testSceneDelegateImplementsConnectionAndDisconnectionSelectors() {
        let scene = CarPlaySceneDelegate()
        XCTAssertTrue(scene.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
        XCTAssertTrue(scene.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
    }
    func testUnavailableSongPresentsANativeCarPlayAlert() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("song.wav"))
        let list = try XCTUnwrap(car.rootTemplate.templates.last as? CPListTemplate)
        let item = try XCTUnwrap(list.sections.first?.items.first as? CPListItem)
        item.handler?(item, {})
        let deadline = Date().addingTimeInterval(4)
        while !(shown.last is CPAlertTemplate) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(shown.last is CPAlertTemplate)
        XCTAssertNotNil(player.issue)
    }
    func testSharedLifecycleRestoresOnceAndDoesNotResetAnActiveSelection() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let services = AppServices(player: player)
        await services.restore()
        player.seek(to: 0.1)
        await services.restore()
        XCTAssertEqual(player.currentTime, 0.1, accuracy: 0.01)
        XCTAssertFalse(player.isPlaying)
    }

    private func row(_ title: String, in template: CPListTemplate) throws -> CPListItem {
        try XCTUnwrap(template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }.first { $0.text == title })
    }

    private func tap(_ title: String, in template: CPListTemplate) async throws {
        let item = try row(title, in: template)
        XCTAssertTrue(item.isEnabled, title)
        var completed = false
        item.handler?(item, { completed = true })
        XCTAssertTrue(completed, title)
        try await Task.sleep(for: .milliseconds(80))
    }

    private func assertOrangeArtwork(_ image: UIImage?) throws {
        let image = try XCTUnwrap(image)
        XCTAssertFalse(image.isSymbolImage)
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 230)
        XCTAssertGreaterThan(pixel[1], 90)
        XCTAssertLessThan(pixel[1], 190)
        XCTAssertLessThan(pixel[2], 25)
    }

    func testNowPlayingControlsUpdateSharedTransportAndNativeCommandState() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        car.start(); defer { car.stop() }
        let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
        XCTAssertEqual(buttons.count, 5)
        XCTAssertTrue(buttons[1] is CPNowPlayingShuffleButton)
        XCTAssertTrue(buttons[2] is CPNowPlayingRepeatButton)
        XCTAssertTrue(buttons[3] is CPNowPlayingPlaybackRateButton)
        let track = try XCTUnwrap(player.current)
        car.perform(.favorite)
        XCTAssertTrue(player.isFavorite(track))
        XCTAssertTrue(buttons[0].isSelected)
        car.perform(.shuffle)
        car.perform(.repeatMode)
        car.perform(.rate)
        try await Task.sleep(for: .milliseconds(150))
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(player.shuffle)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.equalizer.playback.rate, 1.1, accuracy: 0.001)
        XCTAssertEqual(center.changeShuffleModeCommand.currentShuffleType, .items)
        XCTAssertEqual(center.changeRepeatModeCommand.currentRepeatType, .all)
        XCTAssertEqual(center.changePlaybackRateCommand.supportedPlaybackRates, SystemPlaybackControls.playbackRates.map { NSNumber(value: $0) })
        car.perform(.repeatMode); XCTAssertEqual(player.repeatMode, .one)
        car.perform(.repeatMode); XCTAssertEqual(player.repeatMode, .off)
        player.toggleFavorite(track); player.shuffle = false; player.repeatMode = .one
        player.setPlaybackAdjustment(rate: 1.25, semitones: 3)
        // The app test host has another paused player. Read this controller's
        // synchronous publication before its ticker can replace the shared center.
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.25)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(buttons[0].isSelected)
        XCTAssertEqual(center.changeShuffleModeCommand.currentShuffleType, .off)
        XCTAssertEqual(center.changeRepeatModeCommand.currentRepeatType, .one)
        XCTAssertEqual(player.equalizer.playback.rate, 1.25)
        XCTAssertFalse(player.isPlaying, "Changing CarPlay settings must preserve pause intent")
        car.stop()
        car.perform(.shuffle)
        XCTAssertFalse(player.shuffle)
        XCTAssertTrue(CPNowPlayingTemplate.shared.nowPlayingButtons.isEmpty)
    }

    func testAudioPagesReflectPhoneChangesAndKeepSpeedIndependentOfPitch() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        car.perform(.audio)
        let audio = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Tonalidad", in: audio)
        let pitch = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Subir un semitono", in: pitch)
        XCTAssertEqual(player.equalizer.playback.semitones, 1)
        XCTAssertEqual(player.equalizer.playback.rate, 1)
        XCTAssertNotNil(try row("+1 semitonos", in: pitch))
        player.setPlaybackAdjustment(rate: 1.25, semitones: 12)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try row("Subir un semitono", in: pitch).isEnabled)
        XCTAssertEqual(try row("Tonalidad", in: audio).detailText, "+12 semitonos")
        try await tap("Tono original", in: pitch)
        XCTAssertEqual(player.equalizer.playback.rate, 1.25)
        try await tap("Velocidad", in: audio)
        let rates = try XCTUnwrap(shown.last as? CPListTemplate)
        player.setPlaybackAdjustment(semitones: -4)
        let slow = Float(0.75).formatted(.number.precision(.fractionLength(0...2))) + "×"
        try await tap(slow, in: rates)
        XCTAssertEqual(player.equalizer.playback.rate, 0.75)
        XCTAssertEqual(player.equalizer.playback.semitones, -4)
        XCTAssertNotNil(try row(slow, in: rates).accessoryImage)
        try await tap("Restablecer velocidad y tono", in: audio)
        XCTAssertTrue(player.equalizer.playback.isOriginal)
        XCTAssertFalse(try row("Restablecer velocidad y tono", in: audio).isEnabled)
        XCTAssertFalse(player.isPlaying)
    }

    func testListeningPagesApplyEQTransitionsNormalizationBalanceAndSleepTimer() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        car.perform(.audio)
        let audio = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Ecualizador", in: audio)
        let eq = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Rock", in: eq)
        XCTAssertTrue(player.equalizer.settings.enabled); XCTAssertEqual(player.equalizer.preset, .rock)
        try await tap("Desactivar ecualizador", in: eq)
        XCTAssertFalse(player.equalizer.settings.enabled); XCTAssertEqual(player.equalizer.preset, .rock)
        try await tap("Entre canciones", in: audio)
        let transitions = try XCTUnwrap(shown.last as? CPListTemplate)
        XCTAssertFalse(try row("7 s", in: transitions).isEnabled)
        try await tap("Mezcla automática (beta)", in: transitions)
        try await tap("7 s", in: transitions)
        XCTAssertEqual(player.transitionSettings.mode, .adaptive); XCTAssertEqual(player.transitionSettings.duration, 7)
        try await tap("Igualar volumen", in: audio)
        try await tap("Por álbum", in: XCTUnwrap(shown.last as? CPListTemplate))
        XCTAssertEqual(player.listeningSettings.normalization, .album)
        try await tap("Balance", in: audio)
        let balance = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Más a la izquierda", in: balance)
        XCTAssertEqual(player.listeningSettings.balance, -0.1, accuracy: 0.001)
        try await tap("Centrar balance", in: balance)
        XCTAssertEqual(player.listeningSettings.balance, 0)
        try await tap("Temporizador", in: audio)
        let timer = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("15 minutos", in: timer)
        if case .deadline(let deadline) = player.sleepTimer {
            XCTAssertEqual(deadline.timeIntervalSinceNow, 900, accuracy: 2)
        } else { XCTFail("Expected a deadline") }
        try await tap("Al terminar la canción", in: timer)
        XCTAssertEqual(player.sleepTimer, .endOfTrack(try XCTUnwrap(player.current?.id)))
        try await tap("Desactivar temporizador", in: timer)
        XCTAssertNil(player.sleepTimer)
        XCTAssertFalse(player.isPlaying)
    }

    func testEmptyPlayerDisablesTransportAndPoppedPagesReleaseTheirContent() throws {
        let player = PlaybackController(defaults: UserDefaults(suiteName: "CarPlay.Empty.\(UUID())")!)
        defer { player.stop() }
        let car = CarPlayCoordinator(player: player, present: { _ in })
        car.start(); defer { car.stop() }
        XCTAssertTrue(CPNowPlayingTemplate.shared.nowPlayingButtons.prefix(4).allSatisfy { !$0.isEnabled })
        XCTAssertFalse(CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled)
        XCTAssertFalse(CPNowPlayingTemplate.shared.isUpNextButtonEnabled)
        var page: CPListTemplate? = car.list("Temporal") { [] }
        let content = WeakCarPlayPage(value: page?.userInfo as? CarPlayPage)
        XCTAssertNotNil(content.value)
        page = nil
        XCTAssertNil(content.value)
    }

    func testSearchUsesLibraryMetadataAndAlbumArtistNavigationStaysLive() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        let deadline = Date().addingTimeInterval(3)
        while (player.library.isIndexing || player.library.allSongs.isEmpty || player.library.albums.isEmpty)
                && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(player.library.allSongs.isEmpty)
        let home = try XCTUnwrap(car.rootTemplate.templates.first as? CPListTemplate)
        if #available(iOS 27, *) {
            try await tap("Buscar", in: home)
            let search = try XCTUnwrap(shown.last as? CPSearchTemplate)
            var results: [CPListItem] = []
            car.searchTemplate(search, updatedSearchText: "SONG") { results = $0 }
            XCTAssertEqual(results.map(\.text), ["song"])
            car.searchTemplate(search, updatedSearchText: "missing fixture") { results = $0 }
            XCTAssertTrue(results.isEmpty)
            car.searchTemplate(search, updatedSearchText: "song") { results = $0 }
            var completed = false
            car.searchTemplate(search, selectedResult: try XCTUnwrap(results.first)) { completed = true }
            XCTAssertTrue(completed)
            XCTAssertTrue(shown.last === CPNowPlayingTemplate.shared)
        } else {
            XCTAssertFalse(home.sections.flatMap(\.items).contains { ($0 as? CPListItem)?.text == "Buscar" })
        }
        car.nowPlayingTemplateAlbumArtistButtonTapped(.shared)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual((shown.last as? CPListTemplate)?.title, "Álbum y artista")
        XCTAssertEqual((shown.last as? CPListTemplate)?.sections.first?.items.count, 2)
    }

    func testAlbumHighlightsAndSongRowsUseRealCachedArtwork() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("cover.png"))
        await player.loadFolder(root, autoPlay: false)
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        let home = try XCTUnwrap(car.rootTemplate.templates.first as? CPListTemplate)
        let deadline = Date().addingTimeInterval(4)
        while (player.library.allSongs.first?.artworkKey == nil || !(home.sections.first?.items.first is CPListImageRowItem))
                && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let covers = try XCTUnwrap(home.sections.first?.items.first as? CPListImageRowItem)
        XCTAssertEqual(covers.gridImages.count, 1)
        try assertOrangeArtwork(covers.gridImages.first)
        var completed = false
        covers.listImageRowHandler?(covers, 0, { completed = true })
        XCTAssertTrue(completed)
        let songs = try XCTUnwrap(shown.last as? CPListTemplate)
        let song = try row("song", in: songs)
        try assertOrangeArtwork(song.image)
        XCTAssertNotNil(player.library.allSongs.first?.artworkKey)
    }

    func testMarkersShowCachedTempoAndSeekWithoutRegeneratingAnalysis() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let track = try XCTUnwrap(player.current)
        let folder = try player.folderAccess(for: track)
        let snapshot = try await player.readMetadata(for: track)
        let result = try await player.musicTools.load(track: track, folder: folder, expected: snapshot.fingerprint)
        _ = try await player.musicTools.save(SongAnnotations(bpm: 123.4, markers: [.init(time: 0.5, title: "Estribillo")]),
                                             for: track, folder: folder, result: result)
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        car.perform(.audio)
        let audio = try XCTUnwrap(shown.last as? CPListTemplate)
        XCTAssertEqual(try row("BPM y marcadores", in: audio).detailText, "123 BPM")
        try await tap("BPM y marcadores", in: audio)
        let markers = try XCTUnwrap(shown.last as? CPListTemplate)
        try await tap("Estribillo", in: markers)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.02)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(shown.last === CPNowPlayingTemplate.shared)
    }

    func testOpenQueueUpdatesAndOldRowsResolveTrackIdentityAfterReordering() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("song.wav"), to: root.appendingPathComponent("other.wav"))
        await player.loadFolder(root, autoPlay: false)
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        car.nowPlayingTemplateUpNextButtonTapped(.shared)
        try await Task.sleep(for: .milliseconds(100))
        let queue = try XCTUnwrap(shown.last as? CPListTemplate)
        let original = try XCTUnwrap(player.queue.tracks.first)
        let oldRow = try XCTUnwrap(queue.sections.first?.items.first as? CPListItem)
        player.move(from: IndexSet(integer: 0), to: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual((queue.sections.first?.items.first as? CPListItem)?.text, "song")
        oldRow.handler?(oldRow, {})
        let deadline = Date().addingTimeInterval(3)
        while player.current?.id != original.id && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.current?.id, original.id)
        player.pause()
        let position = try XCTUnwrap(player.queue.tracks.firstIndex { $0.id == original.id })
        player.remove(at: IndexSet(integer: position))
        try await Task.sleep(for: .milliseconds(100))
        let selected = player.current?.id, presentations = shown.count
        oldRow.handler?(oldRow, {})
        XCTAssertEqual(player.current?.id, selected)
        XCTAssertEqual(shown.count, presentations)
        XCTAssertEqual(queue.sections.first?.items.count, 1)
    }

    func testCollectionQueueActionsPreserveCurrentSongAndShowTheUpdatedQueue() async throws {
        let (player, root) = try await player()
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("song.wav"), to: root.appendingPathComponent("other.wav"))
        await player.loadFolder(root, autoPlay: false)
        let current = try XCTUnwrap(player.current)
        let added = try XCTUnwrap(player.queue.tracks.last)
        let addedID = try XCTUnwrap(player.libraryID(for: added))
        player.remove(at: IndexSet(integer: 1))
        var shown: [CPTemplate] = []
        let car = CarPlayCoordinator(player: player, present: { shown.append($0) })
        car.start(); defer { car.stop() }
        car.showQueueActions(title: "Colección", ids: { [addedID] })
        try await tap("Añadir al final", in: XCTUnwrap(shown.last as? CPListTemplate))
        XCTAssertEqual(player.current?.id, current.id)
        XCTAssertEqual(player.queue.tracks.last?.localID, added.localID)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual((shown.last as? CPListTemplate)?.title, "Cola")
        car.showQueueActions(title: "Colección", ids: { [addedID] })
        try await tap("Reproducir después", in: XCTUnwrap(shown.last as? CPListTemplate))
        XCTAssertEqual(player.queue.tracks.count, 2)
        XCTAssertEqual(player.current?.id, current.id)
        XCTAssertFalse(player.isPlaying)
    }
}
