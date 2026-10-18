import AVFAudio
import MediaPlayer
import Observation
import SFBAudioEngine
import SonoraCore

@MainActor @Observable
final class PlaybackController: NSObject {
    let equalizer: AudioEqualizer
    let library: MusicLibrary
    let volumeAnalysis: VolumeAnalysisStore
    let localImports: LocalImportController
    @ObservationIgnored lazy var linkImports = LinkImportController(library: library, copies: localImports)
    private(set) var transitionSettings: TransitionSettings
    private(set) var lastTransition: TransitionOutcome?
    private(set) var sleepTimer: SleepTimer?
    private(set) var listeningSettings: ListeningSettings
    private(set) var queue = PlaybackQueue()
    private(set) var details: [String: TrackDetails] = [:]
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var isPreparing = false
    var isDeletingFiles: Bool { library.isDeletingFiles }
    private(set) var folderName = "Tu música"
    var issue: String?
    var repeatMode: RepeatMode = .off { didSet { if oldValue != repeatMode { rebuildBufferedQueue() } } }
    var shuffle = false { didSet {
        if oldValue != shuffle {
            shufflePlayed = Set([current?.id].compactMap { $0 })
            rebuildBufferedQueue()
        }
    } }

    @ObservationIgnored private let player: AudioPlayer
    @ObservationIgnored private var events: PlayerEvents!
    @ObservationIgnored private var folder: ScopedFolder?
    @ObservationIgnored private var bookmark: Data?
    @ObservationIgnored private var extraFolders: [String: ScopedFolder] = [:]
    @ObservationIgnored private var primaryLibraryID: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var entries: [ObjectIdentifier: Entry] = [:]
    @ObservationIgnored private var failedTracks: Set<String> = []
    @ObservationIgnored private var shufflePlayed: Set<String> = []
    @ObservationIgnored private var plannedTracks: Set<String> = []
    @ObservationIgnored private var transitionTail: (id: ObjectIdentifier, entry: Entry)?
    @ObservationIgnored private var recoveringDecoder: ObjectIdentifier?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var pauseRevision = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var lookAhead: Task<Void, Never>?
    @ObservationIgnored private var lookAheadID = UUID()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var systemControls: SystemPlaybackControls?
    @ObservationIgnored private var playIntent = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var resumePosition: Double = 0
    private struct Entry {
        let trackID: String
        let generation: UUID
        let position: Double
        var handoff: CrossfadeHandoff? = nil
        var transition: TransitionOutcome? = nil
    }
    var current: AudioTrack? { queue.current }
    var currentDetails: TrackDetails? { current.flatMap { details[$0.id] } }
    var duration: Double { currentDetails?.duration ?? 0 }
    func setSleepTimer(_ timer: SleepTimer?) {
        let wasEnd = stopsAfterCurrent
        var timer = timer
        if case .deadline(let date) = timer, date <= Date() { timer = nil }
        if case .endOfTrack(let id) = timer, id != current?.id { timer = nil }
        storeSleepTimer(timer)
        if wasEnd || stopsAfterCurrent { rebuildBufferedQueue() }
    }
    private func storeSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        if let timer, let data = try? JSONEncoder().encode(timer) { defaults.set(data, forKey: "sleepTimer") }
        else { defaults.removeObject(forKey: "sleepTimer") }
    }
    private var stopsAfterCurrent: Bool { current.map { sleepTimer == .endOfTrack($0.id) } ?? false }
    private var usesOverlap: Bool { transitionSettings.mode != .continuous && !stopsAfterCurrent }
    func setListening(normalization: NormalizationMode? = nil, balance: Float? = nil) {
        let value = ListeningSettings(normalization: normalization ?? listeningSettings.normalization, balance: balance ?? listeningSettings.balance).validated
        guard value != listeningSettings else { return }
        listeningSettings = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "listeningSettings") }
        rebuildBufferedQueue()
    }

    func folderAccess(for track: AudioTrack) throws -> ScopedFolder {
        if let id = track.sourceID {
            if let access = extraFolders[id] { return access }
            let access = try library.access(id); extraFolders[id] = access; return access
        }
        guard let folder else { throw CocoaError(.fileReadNoPermission) }
        return folder
    }
    func location(for track: AudioTrack) -> String {
        guard let source = track.sourceID else { return track.relativePath }
        return (library.state.sources.first { $0.id == source }?.name ?? extraFolders[source]?.url.lastPathComponent ?? "Carpeta") + "/" + track.relativePath
    }
    func libraryID(for track: AudioTrack) -> String? { (track.sourceID ?? primaryLibraryID).map { $0 + "\0" + track.localID } }
    func toggleFavorite(_ track: AudioTrack) { if let id = libraryID(for: track) { library.toggleFavorite(id) } }
    func isFavorite(_ track: AudioTrack) -> Bool { libraryID(for: track).map { library.state.favorites.contains($0) } ?? false }
    func readMetadata(for track: AudioTrack) async throws -> MetadataSnapshot {
        let access = try folderAccess(for: track)
        let value = try await MetadataService.read(url: track.url(in: access.url), folder: access)
        guard track.cue != nil else { return value }
        return MetadataSnapshot(values: track.tags(overriding: value.values), artwork: value.artwork, fingerprint: value.fingerprint,
                                canWrite: false, fileDescription: value.fileDescription + " · Pista CUE", duration: track.duration(in: value.duration), replayGain: value.replayGain)
    }
    func saveMetadata(for track: AudioTrack, expected: FileFingerprint, patch: MetadataPatch) async throws {
        guard track.cue == nil else { throw MusicTextError.invalid("Una pista CUE comparte el archivo de audio. Sus etiquetas se leen del CUE; no se puede sobrescribir el archivo desde esta pista.") }
        let access = try folderAccess(for: track)
        let source = track.sourceID ?? primaryLibraryID
        try await metadataTransaction { token in
            let saved = try await MetadataService.save(url: track.url(in: access.url), folder: access, expected: expected, patch: patch)
            if let id = libraryID(for: track) { try volumeAnalysis.rebind(id, from: expected, to: saved.fingerprint) }
            if generation == token { details.removeValue(forKey: track.id) }
            if let source { await library.refresh(track: track, source: source, folder: access) }
        }
    }
    func saveMetadataBatch(_ tracks: [AudioTrack], expected: [String: FileFingerprint], patch: MetadataPatch, progress: @escaping @MainActor (Int) -> Void) async -> MetadataBatchResult {
        let primary = primaryLibraryID
        return await metadataTransaction { token in
            var written = 0, failures: [MetadataWriteFailure] = []
            for (index, track) in tracks.enumerated() {
                if Task.isCancelled {
                    failures.append(contentsOf: tracks[index...].map { MetadataWriteFailure(id: $0.id, filename: location(for: $0), message: "Cancelado; no se ha modificado.") }); break
                }
                do {
                    guard track.cue == nil else { throw MusicTextError.invalid("Las pistas CUE no permiten editar etiquetas del audio compartido.") }
                    guard let fingerprint = expected[track.id] else { throw MetadataIOError.changed }
                    let access = try folderAccess(for: track)
                    let saved = try await MetadataService.save(url: track.url(in: access.url), folder: access, expected: fingerprint, patch: patch)
                    if let id = libraryID(for: track) { try volumeAnalysis.rebind(id, from: fingerprint, to: saved.fingerprint) }
                    if generation == token { details.removeValue(forKey: track.id) }
                    if let source = track.sourceID ?? primary { await library.refresh(track: track, source: source, folder: access) }
                    written += 1
                } catch { failures.append(MetadataWriteFailure(id: track.id, filename: location(for: track), message: error.localizedDescription)) }
                progress(index + 1)
            }
            return MetadataBatchResult(written: written, failures: failures)
        }
    }
    func metadataTransaction<T>(_ body: (UUID) async throws -> T) async rethrows -> T {
        refresh()
        let selected = current?.id, position = resumePosition, shouldResume = playIntent, intent = pauseRevision
        invalidatePlayback(); playIntent = false
        let token = generation
        defer {
            if generation == token, let selected, current?.id == selected {
                requestPlayback(trackID: selected, position: position, start: shouldResume && pauseRevision == intent)
            }
        }
        return try await body(token)
    }

    init(defaults: UserDefaults = .standard, audioPlayer: AudioPlayer = AudioPlayer(), localStorage: URL = LocalMusicImport.defaultStorage) {
        self.defaults = defaults
        player = audioPlayer
        library = MusicLibrary(defaults: defaults)
        volumeAnalysis = VolumeAnalysisStore(defaults: defaults)
        localImports = LocalImportController(storage: localStorage)
        let listening = defaults.data(forKey: "listeningSettings").flatMap { try? JSONDecoder().decode(ListeningSettings.self, from: $0) }?.validated ?? ListeningSettings()
        listeningSettings = listening
        var timer = defaults.data(forKey: "sleepTimer").flatMap { try? JSONDecoder().decode(SleepTimer.self, from: $0) }
        if case .deadline(let date) = timer, date <= Date() { timer = nil; defaults.removeObject(forKey: "sleepTimer") }
        sleepTimer = timer
        equalizer = AudioEqualizer(defaults: defaults, player: audioPlayer)
        transitionSettings = defaults.data(forKey: "transitionSettings")
            .flatMap { try? JSONDecoder().decode(TransitionSettings.self, from: $0) }?.validated ?? TransitionSettings()
        super.init()
        events = PlayerEvents(equalizer: equalizer.processor) { [weak self] event in Task { @MainActor in self?.handle(event) } }
        player.delegate = events
        systemControls = SystemPlaybackControls(owner: self)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    isolated deinit {
        library.cancelIndexing()
        ticker?.cancel(); loadTask?.cancel(); preparation?.cancel(); lookAhead?.cancel()
        entries.values.forEach { $0.handoff?.cancel() }; transitionTail?.entry.handoff?.cancel()
        player.delegate = nil
        player.stop()
    }
    func chooseFolder(_ url: URL, name: String? = nil) {
        loadTask?.cancel()
        loadTask = Task { await loadFolder(url, name: name) }
    }
    func cancelLoading() { loadTask?.cancel(); loadID = UUID(); isLoading = false }
    func appendFolder(_ url: URL, playNext: Bool = false) async {
        guard !isDeletingFiles else { return }
        if queue.tracks.isEmpty { await loadFolder(url, autoPlay: false); return }
        let request = UUID(); loadID = request; isLoading = true; issue = nil
        defer { if loadID == request { isLoading = false } }
        do {
            let access = try ScopedFolder(url)
            let tracks = try await FolderScanService.scan(access)
            try Task.checkCancellation(); guard loadID == request else { return }
            guard !tracks.isEmpty else { throw PlayerError.emptyFolder }
            let source = try library.register(access, tracks: tracks)
            let isPrimary = folder?.url.standardizedFileURL == access.url.standardizedFileURL
            if !isPrimary { extraFolders[source] = access }
            let incoming = tracks.map { $0.withSource(isPrimary ? nil : source) }
            refresh(); queue.insert(incoming, afterCurrent: playNext); rebuildBufferedQueue()
            if Set(queue.tracks.map { $0.sourceID ?? "" }).count > 1 { folderName = "Cola de varias carpetas" }
            save()
        } catch is CancellationError { }
        catch { if loadID == request { issue = error.localizedDescription } }
    }
    func chooseAdditionalFolder(_ url: URL, playNext: Bool = false) {
        loadTask?.cancel(); loadTask = Task { await appendFolder(url, playNext: playNext) }
    }
    func enqueue(_ track: AudioTrack, playNext: Bool) {
        guard !isDeletingFiles else { return }
        refresh(); queue.insert([track], afterCurrent: playNext); rebuildBufferedQueue(); save()
    }
    func addFolderToLibrary(_ url: URL) {
        guard !isDeletingFiles else { return }
        loadTask?.cancel()
        loadTask = Task {
            let request = UUID(); loadID = request; isLoading = true
            defer { if loadID == request { isLoading = false } }
            do {
                let access = try ScopedFolder(url)
                let tracks = try await FolderScanService.scan(access)
                try Task.checkCancellation(); guard loadID == request else { return }
                guard !tracks.isEmpty else { throw PlayerError.emptyFolder }
                try library.register(access, tracks: tracks)
            } catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
    func playSongs(_ ids: [String], startingAt id: String? = nil) {
        guard !isDeletingFiles else { return }
        loadTask?.cancel()
        loadTask = Task {
            var scopes: [String: ScopedFolder] = [:], tracks: [AudioTrack] = []
            for value in ids {
                guard let song = library.state.songs[value], let track = song.audioTrack else { continue }
                do { if scopes[song.sourceID] == nil { scopes[song.sourceID] = try library.access(song.sourceID) }; tracks.append(track) }
                catch { issue = "Vuelve a abrir la carpeta \(library.state.sources.first { $0.id == song.sourceID }?.name ?? "de esta canción") para recuperar el acceso." }
            }
            await loadQueue(tracks: tracks, scopes: scopes, selected: id, position: 0, name: "Biblioteca", autoPlay: true, primaryID: nil)
        }
    }
    func enqueueSongs(_ ids: [String], playNext: Bool) {
        guard !isDeletingFiles else { return }
        var tracks: [AudioTrack] = []
        for id in ids {
            guard let song = library.state.songs[id] else { continue }
            do {
                if song.sourceID == primaryLibraryID, folder != nil {
                    if let track = song.audioTrack { tracks.append(track.withSource(nil)) }
                } else {
                    extraFolders[song.sourceID] = try library.access(song.sourceID)
                    if let track = song.audioTrack { tracks.append(track) }
                }
            } catch { issue = error.localizedDescription }
        }
        guard !tracks.isEmpty else { return }
        refresh(); queue.insert(tracks, afterCurrent: playNext)
        folderName = "Cola de la biblioteca"; rebuildBufferedQueue(); save()
    }
    func forgetSource(_ id: String) {
        volumeAnalysis.forget(Set(library.state.songs.values.filter { $0.sourceID == id }.map(\.id)))
        let offsets = IndexSet(queue.tracks.indices.filter { queue.tracks[$0].sourceID == id || (primaryLibraryID == id && queue.tracks[$0].sourceID == nil) })
        remove(at: offsets)
        if primaryLibraryID == id { folder = nil; bookmark = nil; primaryLibraryID = nil }
        extraFolders.removeValue(forKey: id); library.forgetSource(id); save()
    }
    func deleteSourceFile(_ item: SourceFile, sourceID: String) async throws {
        let access = try library.access(sourceID)
        guard AudioTrack(relativePath: item.relativePath) != nil else { throw CocoaError(.fileWriteNoPermission) }
        try await deleteFiles(at: access.url.appendingPathComponent(item.relativePath)) {
            try await SourceFileService.remove(item, from: access)
        }
    }
    func deleteLocalCopy(_ copy: ImportedMusicRecord) async throws {
        let target = localImports.musicURL(copy).deletingLastPathComponent()
        try await deleteFiles(at: target) { try await localImports.remove(copy) }
    }
    /// Release current and prebuffered decoders before touching files. Reconcile
    /// every overlapping source, including CUE identities, before resuming audio.
    private func deleteFiles(at target: URL, operation: () async throws -> Void) async throws {
        guard !isDeletingFiles, !localImports.isImporting, !linkImports.isImporting else {
            throw MusicTextError.invalid("Espera a que termine la operación actual.")
        }
        guard !library.needsReset else { throw MusicTextError.invalid("Restablece la biblioteca antes de borrar archivos.") }
        let targetPath = target.standardizedFileURL.resolvingSymlinksInPath().path
        func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }
        var affected: [String: ScopedFolder] = [:]
        for source in library.state.sources {
            guard let url = try? library.sourceURL(source.id) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if contains(path, targetPath) || contains(targetPath, path) { affected[source.id] = try library.access(source.id) }
        }
        let affectedIDs = Set(affected.keys)
        let copies = localImports.copies.filter {
            let path = localImports.musicURL($0).standardizedFileURL.resolvingSymlinksInPath().path
            return contains(path, targetPath) || contains(targetPath, path)
        }
        let oldSongs = library.state.songs
        let dependentSheets = Set(oldSongs.values.compactMap { song -> String? in
            guard let scope = affected[song.sourceID], let cue = song.cue,
                  contains(targetPath, scope.url.appendingPathComponent(song.relativePath).standardizedFileURL.resolvingSymlinksInPath().path),
                  !contains(targetPath, scope.url.appendingPathComponent(cue.sheetPath).standardizedFileURL.resolvingSymlinksInPath().path) else { return nil }
            return cue.sheetPath
        })
        guard dependentSheets.isEmpty else {
            throw MusicTextError.invalid("Este audio tiene pistas CUE. Elimina primero el CUE (\(dependentSheets.sorted().prefix(3).joined(separator: ", "))) o borra una carpeta que contenga también esos CUE.")
        }
        let queuedLibraryIDs = Dictionary(uniqueKeysWithValues: queue.tracks.compactMap { track in libraryID(for: track).map { (track.id, $0) } })
        let affectedQueue = Set(queue.tracks.filter { affectedIDs.contains($0.sourceID ?? primaryLibraryID ?? "") }.map(\.id))
        cancelLoading(); library.beginFileDeletion(for: affectedIDs)
        refresh()
        let selected = current?.id, position = resumePosition, shouldResume = playIntent, intent = pauseRevision
        invalidatePlayback(); playIntent = false
        let token = generation
        defer {
            library.finishFileDeletion(for: affectedIDs)
            if generation == token {
                if let current { requestPlayback(trackID: current.id, position: current.id == selected ? position : 0, start: shouldResume && pauseRevision == intent) }
                else { stop() }
            }
            save()
        }
        var deletionError: Error?, warnings: [String] = []
        do { try await operation() } catch { deletionError = error }
        // Also rescan on failure: a provider may have removed part of a folder
        // before reporting an error. Never assume a failed recursive write was atomic.
        for (id, access) in affected where library.state.sources.contains(where: { $0.id == id }) {
            let rootPath = access.url.standardizedFileURL.resolvingSymlinksInPath().path
            if deletionError == nil && contains(targetPath, rootPath) { forgetSource(id); continue }
            do {
                let tracks = try await FolderScanService.scan(access)
                // Source registration retains its identity and the tags of surviving songs.
                if library.state.sources.contains(where: { $0.id == id }) { try library.register(access, tracks: tracks) }
            } catch {
                if deletionError == nil {
                    let removed = Set(oldSongs.values.filter { song in
                        guard song.sourceID == id else { return false }
                        return contains(targetPath, access.url.appendingPathComponent(song.relativePath).standardizedFileURL.resolvingSymlinksInPath().path)
                            || song.cue.map { contains(targetPath, access.url.appendingPathComponent($0.sheetPath).standardizedFileURL.resolvingSymlinksInPath().path) } == true
                    }.map(\.id))
                    library.removeSongs(removed)
                }
                warnings.append("No se pudo actualizar una fuente: \(error.localizedDescription)")
            }
        }
        let removed = Set(oldSongs.keys).subtracting(library.state.songs.keys)
        library.removeSongs(removed); volumeAnalysis.forget(removed)
        queue.remove(atOffsets: IndexSet(queue.tracks.indices.filter { index in
            let track = queue.tracks[index]
            return queuedLibraryIDs[track.id].map { removed.contains($0) } ?? false
        }))
        details = details.filter { !affectedQueue.contains($0.key) }
        if case .endOfTrack(let id) = sleepTimer, current?.id != id { storeSleepTimer(nil) }
        for copy in copies where localImports.copies.contains(where: { $0.id == copy.id }) {
            do { try await localImports.refresh(copy) }
            catch { warnings.append("No se pudo actualizar el tamaño de la copia local: \(error.localizedDescription)") }
        }
        if !warnings.isEmpty { issue = warnings.joined(separator: "\n") }
        if let deletionError { throw deletionError }
    }
    func loadFolder(_ url: URL, autoPlay: Bool = true, name: String? = nil) async { await load(url, autoPlay: autoPlay, restoring: nil, name: name) }

    private func load(_ url: URL, autoPlay: Bool, restoring savedSnapshot: FolderSnapshot?, name: String? = nil) async {
        guard !isDeletingFiles else { return }
        var snapshot = savedSnapshot
        let request = UUID(); let intent = pauseRevision
        loadID = request; isLoading = true; issue = nil
        defer { if loadID == request { isLoading = false } }
        do {
            let access = try ScopedFolder(url)
            let data = try access.bookmark()
            var tracks = try await FolderScanService.scan(access)
            try Task.checkCancellation()
            if let saved = snapshot {
                let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
                let segments = Dictionary(grouping: tracks.filter { $0.cue != nil }, by: \.relativePath)
                var seen: Set<String> = []
                tracks = saved.paths.flatMap { available[$0].map { [$0] } ?? segments[$0] ?? [] }.filter { seen.insert($0.id).inserted }
                if let selected = saved.selectedPath, available[selected] == nil, let songs = segments[selected],
                   let song = songs.last(where: { ($0.cue?.startSeconds ?? 0) <= saved.position }) ?? songs.first {
                    snapshot = FolderSnapshot(bookmark: saved.bookmark, paths: tracks.map(\.localID), selectedPath: song.id,
                                              position: max(0, saved.position - (song.cue?.startSeconds ?? 0)), name: saved.name)
                }
                if tracks.isEmpty {
                    guard loadID == request else { return }
                    invalidatePlayback(); playIntent = false
                    folder = access; bookmark = data; folderName = url.lastPathComponent
                    primaryLibraryID = nil; extraFolders = [:]
                    if case .endOfTrack = sleepTimer { storeSleepTimer(nil) }
                    queue = PlaybackQueue(); details = [:]; currentTime = 0; resumePosition = 0
                    if !saved.paths.isEmpty { issue = "Los archivos guardados ya no están disponibles. Vuelve a abrir la carpeta para crear una cola." }
                    updateNowPlaying(); save()
                    return
                }
            }
            guard !tracks.isEmpty else { throw PlayerError.emptyFolder }
            let start = snapshot?.selectedPath.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
            var first: (Int, PreparedTrack)?
            for index in Array(start..<tracks.count) + Array(0..<start) {
                do { first = (index, try await MediaReader.prepare(tracks[index], folder: access, normalization: listeningSettings.normalization, balance: listeningSettings.balance, analyzeRhythm: transitionSettings.mode == .adaptive && !stopsAfterCurrent, volume: volumeCandidate(for: tracks[index], folder: access, includeAlbum: listeningSettings.normalization == .album))); break }
                catch is CancellationError { throw CancellationError() }
                catch { if loadID == request { issue = "No se pudo abrir \(tracks[index].filename): \(error.localizedDescription)" } }
            }
            guard let (index, prepared) = first else { throw PlayerError.noPlayableFiles }
            if autoPlay && pauseRevision == intent { try await AudioSessionCoordinator.shared.activate() }
            try Task.checkCancellation()
            guard loadID == request else { return }
            let libraryID = try library.register(access, tracks: tracks, name: name ?? snapshot?.name)
            invalidatePlayback()
            folder = access; bookmark = data; folderName = library.state.sources.first { $0.id == libraryID }?.name ?? url.lastPathComponent
            if case .endOfTrack = sleepTimer, snapshot == nil || sleepTimer != .endOfTrack(tracks[index].id) { storeSleepTimer(nil) }
            extraFolders = [:]; primaryLibraryID = libraryID
            queue.replace(with: tracks); queue.select(index: index); shufflePlayed = []
            details = [tracks[index].id: prepared.details]
            let restoredPosition = snapshot?.selectedPath == tracks[index].id ? snapshot?.position ?? 0 : 0
            currentTime = restoredPosition.isFinite ? max(0, min(restoredPosition, prepared.details.duration)) : 0
            resumePosition = currentTime
            playIntent = autoPlay && pauseRevision == intent
            if playIntent { try submit(prepared, trackID: tracks[index].id) }
            updateNowPlaying(); save()
        } catch is CancellationError { }
        catch { if loadID == request { issue = error.localizedDescription } }
    }
    func restoreFolder() async {
        if let data = defaults.data(forKey: "multiFolderQueue") {
            let request = UUID(); loadID = request
            do {
                let snapshot = try JSONDecoder().decode(MultiFolderSnapshot.self, from: data)
                let resolved = try await snapshot.resolve()
                guard loadID == request, !Task.isCancelled else { return }
                let restored = await loadQueue(tracks: resolved.tracks, scopes: resolved.folders, selected: snapshot.selectedID, position: snapshot.position,
                                               name: snapshot.name, autoPlay: false, primaryID: snapshot.primaryLibraryID)
                if restored && resolved.tracks.count < snapshot.tracks.count { issue = "Algunos archivos o carpetas ya no están disponibles. Se ha recuperado el resto de la cola." }
            } catch { issue = "Vuelve a abrir las carpetas para recuperar la cola: \(error.localizedDescription)" }
            return
        }
        guard let data = defaults.data(forKey: "folderSnapshot") else { return }
        do {
            let snapshot = try JSONDecoder().decode(FolderSnapshot.self, from: data)
            var stale = false
            let url = try URL(resolvingBookmarkData: snapshot.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            await load(url, autoPlay: false, restoring: snapshot)
        } catch { issue = "Vuelve a elegir tu carpeta para recuperar el acceso." }
    }
    @discardableResult
    private func loadQueue(tracks: [AudioTrack], scopes: [String: ScopedFolder], selected: String?, position: Double, name: String, autoPlay: Bool, primaryID: String?) async -> Bool {
        guard !isDeletingFiles else { return false }
        let request = UUID(), intent = pauseRevision
        loadID = request; isLoading = true
        defer { if loadID == request { isLoading = false } }
        do {
            guard !tracks.isEmpty else { throw PlayerError.emptyFolder }
            let start = selected.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
            var first: (Int, PreparedTrack)?
            for index in Array(start..<tracks.count) + Array(0..<start) {
                do {
                    guard let access = scopes[tracks[index].sourceID ?? ""] else { throw CocoaError(.fileReadNoPermission) }
                    first = (index, try await MediaReader.prepare(tracks[index], folder: access, normalization: listeningSettings.normalization, balance: listeningSettings.balance, analyzeRhythm: transitionSettings.mode == .adaptive && !stopsAfterCurrent, volume: volumeCandidate(for: tracks[index], folder: access, includeAlbum: listeningSettings.normalization == .album))); break
                } catch is CancellationError { throw CancellationError() }
                catch { if loadID == request { issue = "No se pudo abrir \(tracks[index].filename): \(error.localizedDescription)" } }
            }
            guard let (index, prepared) = first else { throw PlayerError.noPlayableFiles }
            if autoPlay && pauseRevision == intent { try await AudioSessionCoordinator.shared.activate() }
            try Task.checkCancellation(); guard loadID == request else { return false }
            invalidatePlayback()
            folder = scopes[""]; bookmark = try folder?.bookmark()
            extraFolders = scopes.filter { !$0.key.isEmpty }; primaryLibraryID = primaryID; folderName = name
            if case .endOfTrack = sleepTimer, autoPlay || sleepTimer != .endOfTrack(tracks[index].id) { storeSleepTimer(nil) }
            queue.replace(with: tracks); queue.select(index: index); shufflePlayed = []
            details = [:]; cache(prepared.details, for: tracks[index].id)
            let seconds = selected == tracks[index].id ? position : 0
            currentTime = seconds.isFinite ? max(0, min(seconds, prepared.details.duration)) : 0; resumePosition = currentTime
            playIntent = autoPlay && pauseRevision == intent
            if playIntent { try submit(prepared, trackID: tracks[index].id) }
            updateNowPlaying(); save(); return true
        } catch is CancellationError { return false }
        catch { if loadID == request { issue = error.localizedDescription }; return false }
    }
    func play(index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        requestPlayback(trackID: queue.tracks[index].id, position: 0, start: true)
    }
    private func requestPlayback(trackID: String, position: Double, start: Bool) {
        guard !isDeletingFiles else { return }
        guard let index = queue.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = queue.tracks[index]
        if case .endOfTrack(let target) = sleepTimer, target != trackID { storeSleepTimer(nil) }
        guard let folder = try? folderAccess(for: track) else { issue = "Vuelve a abrir la carpeta de esta canción."; return }
        invalidatePlayback(); queue.select(index: index)
        currentTime = position; resumePosition = position; playIntent = start; isPreparing = true
        let token = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await MediaReader.prepare(track, folder: folder, position: position, normalization: listeningSettings.normalization, balance: listeningSettings.balance, analyzeRhythm: transitionSettings.mode == .adaptive && !stopsAfterCurrent, volume: volumeCandidate(for: track, folder: folder, includeAlbum: listeningSettings.normalization == .album))
                try Task.checkCancellation()
                guard generation == token else { return }
                cache(prepared.details, for: trackID)
                if playIntent && !interrupted { try await AudioSessionCoordinator.shared.activate() }
                try Task.checkCancellation()
                guard generation == token else { return }
                isPreparing = false
                if playIntent && !interrupted { try submit(prepared, trackID: trackID, position: position) }
                updateNowPlaying(); save()
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                isPreparing = false; issue = "No se pudo abrir \(track.filename): \(error.localizedDescription)"
                failedTracks.insert(trackID)
                if playIntent, let next = nextCandidates().first {
                    requestPlayback(trackID: next.id, position: 0, start: true, preservingFailures: failedTracks)
                } else { playIntent = false; updateNowPlaying() }
            }
        }
    }
    private func requestPlayback(trackID: String, position: Double, start: Bool, preservingFailures: Set<String>) {
        guard !isDeletingFiles else { return }
        requestPlayback(trackID: trackID, position: position, start: start)
        failedTracks = preservingFailures
    }
    func togglePlayback() {
        if playIntent && (isPlaying || isPreparing) { pause() } else { resume() }
    }
    func resume() {
        guard let current, !isPlaying, !(playIntent && isPreparing) else { return }
        if player.isPaused && player.isReady {
            playIntent = true; let token = generation
            preparation = Task { [weak self] in
                guard let self else { return }
                do {
                    try await AudioSessionCoordinator.shared.activate()
                    guard generation == token, playIntent, !interrupted else { return }
                    try player.play()
                } catch { issue = error.localizedDescription }
            }
        } else { requestPlayback(trackID: current.id, position: resumePosition, start: true) }
    }
    func pause() {
        pauseRevision = UUID()
        refresh(); playIntent = false
        if isPreparing { invalidatePlayback() } else { player.pause() }
        isPlaying = false; updateNowPlaying(); save()
    }
    func stop() {
        pauseRevision = UUID()
        storeSleepTimer(nil)
        refresh(); playIntent = false; invalidatePlayback(); save(); updateNowPlaying()
        let token = generation
        Task { [weak self] in
            guard let self, generation == token, !playIntent else { return }
            try? await AudioSessionCoordinator.shared.deactivate()
        }
    }
    func next() {
        if let next = nextCandidates(automatic: false).first { requestPlayback(trackID: next.id, position: 0, start: playIntent) }
        else { stop() }
    }
    func previous() {
        if currentTime > 3 { seek(to: 0) }
        else if let index = queue.currentIndex { requestPlayback(trackID: queue.tracks[max(0, index - 1)].id, position: 0, start: playIntent) }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, let current else { return }
        let target = max(0, min(max(0, duration - 0.01), seconds))
        if isPreparing { requestPlayback(trackID: current.id, position: target, start: playIntent) }
        else if current.cue != nil || player.isReady && (usesOverlap || listeningSettings.normalization != .off || listeningSettings.balance != 0) {
            // Reopening a virtual interval also invalidates a late rendering-start
            // event that could otherwise replace a just-scrubbed paused position.
            requestPlayback(trackID: current.id, position: target, start: playIntent)
        } else if player.isReady {
            guard player.supportsSeeking, player.seek(time: target) else { issue = "Este archivo no permite cambiar la posición."; return }
        }
        currentTime = target; resumePosition = target; updateNowPlaying(); save()
    }
    func move(from offsets: IndexSet, to destination: Int) {
        refresh(); queue.move(fromOffsets: offsets, toOffset: destination); rebuildBufferedQueue(); save()
    }
    func remove(at offsets: IndexSet) {
        refresh(); let previous = current?.id; let shouldPlay = playIntent
        queue.remove(atOffsets: offsets)
        if current?.id != previous {
            if let current { requestPlayback(trackID: current.id, position: 0, start: shouldPlay) }
            else { stop() }
        } else { rebuildBufferedQueue() }
        save()
    }
    func save() {
        library.persist()
        if queue.tracks.contains(where: { $0.sourceID != nil }) {
            var bookmarks: [String: Data] = [:]
            for id in Set(queue.tracks.map { $0.sourceID ?? "" }) {
                if id.isEmpty { bookmarks[id] = bookmark }
                else if let scope = extraFolders[id] { bookmarks[id] = try? scope.bookmark() }
                else { bookmarks[id] = library.state.sources.first { $0.id == id }?.bookmark }
            }
            let snapshot = MultiFolderSnapshot(bookmarks: bookmarks, tracks: queue.tracks, selectedID: current?.id,
                                              position: resumePosition.isFinite ? resumePosition : 0, name: folderName, primaryLibraryID: primaryLibraryID)
            do { defaults.set(try JSONEncoder().encode(snapshot), forKey: "multiFolderQueue") }
            catch { issue = "No se pudo guardar la cola: \(error.localizedDescription)" }
            return
        }
        defaults.removeObject(forKey: "multiFolderQueue")
        guard let bookmark else { defaults.removeObject(forKey: "folderSnapshot"); return }
        let snapshot = FolderSnapshot(bookmark: bookmark, paths: queue.tracks.map(\.localID), selectedPath: current?.id, position: resumePosition.isFinite ? resumePosition : 0, name: folderName)
        do { defaults.set(try JSONEncoder().encode(snapshot), forKey: "folderSnapshot") }
        catch { issue = "No se pudo guardar la cola: \(error.localizedDescription)" }
    }
    private func invalidatePlayback() {
        generation = UUID(); preparation?.cancel(); lookAhead?.cancel(); lookAhead = nil; lookAheadID = UUID()
        entries.values.forEach { $0.handoff?.cancel() }; transitionTail?.entry.handoff?.cancel()
        transitionTail = nil; recoveringDecoder = nil; plannedTracks = []; lastTransition = nil
        player.stop(); entries.removeAll(); isPlaying = false; isPreparing = false; failedTracks = []
    }
    private func submit(_ prepared: PreparedTrack, trackID: String, position: Double = 0) throws {
        if usesOverlap {
            try submitTransition(TransitionTrack.prepare(prepared, id: trackID))
            return
        }
        let id = ObjectIdentifier(prepared.decoder)
        entries[id] = Entry(trackID: trackID, generation: generation, position: position)
        do {
            try player.enqueue(prepared.decoder)
            if !player.isPlaying && playIntent && !interrupted { try player.play() }
        } catch { entries.removeValue(forKey: id); throw error }
    }
    private func nextCandidates(automatic: Bool = true) -> [AudioTrack] {
        if automatic && stopsAfterCurrent { return [] }
        guard let index = queue.currentIndex else { return [] }
        let tracks = queue.tracks
        if automatic && repeatMode == .one, !failedTracks.contains(tracks[index].id) { return [tracks[index]] }
        let wraps = repeatMode != .off
        let indices: [Int]
        if shuffle {
            let remaining = tracks.indices.filter { $0 != index && !shufflePlayed.contains(tracks[$0].id) }
            indices = remaining.isEmpty && wraps
                ? tracks.indices.filter { tracks.count == 1 || $0 != index }.shuffled()
                : remaining.shuffled()
        } else {
            indices = Array((index + 1)..<tracks.count) + (wraps ? Array(0...index) : [])
        }
        return indices.map { tracks[$0] }.filter { !failedTracks.contains($0.id) }
    }
    private func rebuildBufferedQueue() {
        guard let current, isPlaying || isPreparing || player.isPaused else { return }
        refresh()
        // clearQueue() leaves already decoded audio in SFB's ring buffer. Reopen at the
        // current frame so removed/reordered tracks cannot leak into the audible queue.
        requestPlayback(trackID: current.id, position: resumePosition, start: playIntent)
    }
    func volumeAnalysisDidChange() {
        if listeningSettings.normalization != .off { rebuildBufferedQueue() }
    }
    private func prepareNext() {
        guard !usesOverlap else { return }
        guard lookAhead == nil else { return }
        let candidates = nextCandidates(); let token = generation; let job = UUID(); lookAheadID = job
        guard !candidates.isEmpty else { return }
        lookAhead = Task { [weak self] in
            guard let self else { return }
            defer {
                if lookAheadID == job {
                    lookAhead = nil
                    if !player.isPlaying && !player.isReady && !isPreparing { playIntent = false; save(); updateNowPlaying() }
                }
            }
            for track in candidates {
                do {
                    let folder = try folderAccess(for: track)
                    let prepared = try await MediaReader.prepare(track, folder: folder, normalization: listeningSettings.normalization, balance: listeningSettings.balance, analyzeRhythm: transitionSettings.mode == .adaptive && !stopsAfterCurrent, volume: volumeCandidate(for: track, folder: folder, includeAlbum: listeningSettings.normalization == .album))
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    cache(prepared.details, for: track.id)
                    try submit(prepared, trackID: track.id)
                    isPreparing = false
                    return
                } catch is CancellationError { return }
                catch {
                    guard generation == token else { return }
                    failedTracks.insert(track.id)
                    issue = "No se pudo abrir \(track.filename): \(error.localizedDescription)"
                }
            }
        }
    }
    private func handle(_ event: PlayerEvent) {
        switch event {
        case .started(let id):
            guard let entry = entries[id], entry.generation == generation,
                  let index = queue.tracks.firstIndex(where: { $0.id == entry.trackID }) else { return }
            if recoveringDecoder == id { recoveringDecoder = nil }
            if shuffle {
                if current?.id != entry.trackID && shufflePlayed.contains(entry.trackID) && repeatMode == .all { shufflePlayed = [] }
                shufflePlayed.insert(entry.trackID)
            }
            queue.select(index: index); currentTime = entry.position; resumePosition = entry.position; isPreparing = false
            if let source = queue.current?.sourceID ?? primaryLibraryID, let current = queue.current {
                library.recordPlayed(source + "\0" + current.localID)
            }
            if let transition = entry.transition { lastTransition = transition }
            prepareNext(); refresh(); save()
        case .decoded(let id):
            if let entry = transitionEntry(id), entry.generation == generation, let handoff = entry.handoff {
                handoff.finishDecoding(); enqueueTransition(after: id)
            }
        case .released(let id):
            entries.removeValue(forKey: id)
            if recoveringDecoder == id { recoveringDecoder = nil }
            if let tail = transitionTail { prepareTransition(after: tail.id) }
        case .state:
            // SFB reports decodingAborted before stopping its empty engine. Our
            // asynchronous successor can be enqueued and played in that window.
            // Restart only that pending recovery after the delayed stop event.
            if let recoveringDecoder, entries[recoveringDecoder] != nil,
               playIntent, !interrupted, player.isReady, !player.isPlaying {
                do { try player.play() }
                catch { issue = error.localizedDescription; playIntent = false }
            }
            isPlaying = player.isPlaying && playIntent && !interrupted
            updateNowPlaying()
        case .ended:
            if let tail = transitionTail { enqueueTransition(after: tail.id) }
            // With an end-of-audio delegate SFB deliberately leaves stopping to us.
            // Its isPlaying flag can still be true after the last rendered frame.
            guard player.nowPlaying == nil, !player.isReady, player.queueIsEmpty, !isPreparing else { return }
            if stopsAfterCurrent { storeSleepTimer(nil) }
            player.pause(); isPlaying = false
            if lookAhead != nil && playIntent { isPreparing = true }
            else { playIntent = false; player.stop(); currentTime = duration; resumePosition = 0; save() }
            updateNowPlaying()
        case .failed(let id, let message):
            if let id {
                guard let entry = entries.removeValue(forKey: id), entry.generation == generation else { return }
                failedTracks.insert(entry.trackID); issue = message
                if sleepTimer == .endOfTrack(entry.trackID) { stop(); return }
                if entry.handoff != nil {
                    entry.handoff?.cancel()
                    if transitionTail?.id == id {
                        // The failed decoder may still have audible buffered frames.
                        // Reopen its successor at zero rather than reusing a head that
                        // was consumed for a transition which never reached the output.
                        lookAhead?.cancel(); lookAhead = nil; lookAheadID = UUID()
                        let handoff = CrossfadeHandoff(); handoff.finishDecoding(outcome: .sourceFailed)
                        var replacement = entry; replacement.handoff = handoff
                        transitionTail = (id, replacement)
                        prepareTransition(after: id)
                    }
                    return
                }
                if !player.isReady && playIntent, let next = nextCandidates().first {
                    requestPlayback(trackID: next.id, position: 0, start: true, preservingFailures: failedTracks)
                } else if player.isPlaying { prepareNext() }
            } else { issue = message; pause() }
        }
    }

    func setTransition(mode: TransitionMode? = nil, duration: Double? = nil) {
        let value = TransitionSettings(mode: mode ?? transitionSettings.mode, duration: duration ?? transitionSettings.duration).validated
        guard value != transitionSettings else { return }
        transitionSettings = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "transitionSettings") }
        rebuildBufferedQueue()
    }

    private func transitionEntry(_ id: ObjectIdentifier) -> Entry? {
        entries[id] ?? (transitionTail?.id == id ? transitionTail?.entry : nil)
    }
    private func submitTransition(_ track: TransitionTrack, outcome: TransitionOutcome? = nil) throws {
        let handoff = CrossfadeHandoff()
        let source = track.prepared.decoder
        let position = Double(max(0, source.position)) / source.processingFormat.sampleRate
        let decoder: any PCMDecoding
        if let source = source as? NormalizedPCMDecoder {
            decoder = CrossfadeDecoder(source, handoff: handoff, duration: transitionSettings.duration,
                adaptive: transitionSettings.mode == .adaptive ? track.prepared.details.rhythm ?? .unavailable("No hay un análisis disponible.") : nil)
        } else { decoder = source }
        let id = ObjectIdentifier(decoder)
        let entry = Entry(trackID: track.id, generation: generation, position: position, handoff: handoff, transition: outcome)
        entries[id] = entry; transitionTail = (id, entry)
        if case .sourceFailed = outcome { recoveringDecoder = id }
        if shuffle && plannedTracks.contains(track.id) && repeatMode == .all { plannedTracks = [] }
        plannedTracks.insert(track.id)
        cache(track.prepared.details, for: track.id)
        // Start I/O before enqueue: SFB can decode short tracks immediately, before
        // renderingStarted reaches MainActor. The worker supplies the handoff itself.
        prepareTransition(after: id)
        do {
            try player.enqueue(decoder)
            if !player.isPlaying && playIntent && !interrupted { try player.play() }
        } catch { handoff.cancel(); entries.removeValue(forKey: id); throw error }
    }
    private func transitionCandidates(after trackID: String) -> [AudioTrack] {
        if sleepTimer == .endOfTrack(trackID) { return [] }
        guard let index = queue.tracks.firstIndex(where: { $0.id == trackID }) else { return [] }
        let tracks = queue.tracks
        if repeatMode == .one, !failedTracks.contains(trackID) { return [tracks[index]] }
        let indices: [Int]
        if shuffle {
            let remaining = tracks.indices.filter { $0 != index && !plannedTracks.contains(tracks[$0].id) }
            indices = remaining.isEmpty && repeatMode == .all
                ? tracks.indices.filter { tracks.count == 1 || $0 != index }.shuffled() : remaining.shuffled()
        } else {
            indices = Array((index + 1)..<tracks.count) + (repeatMode == .all ? Array(0...index) : [])
        }
        return indices.map { tracks[$0] }.filter { !failedTracks.contains($0.id) }
    }
    private func prepareTransition(after id: ObjectIdentifier) {
        // Bound queued decoder/metadata ownership even for folders of tiny clips.
        guard lookAhead == nil, entries.count < 8,
              let entry = transitionEntry(id), entry.generation == generation,
              let handoff = entry.handoff, handoff.beginPreparation() else { return }
        let candidates = transitionCandidates(after: entry.trackID)
        guard !candidates.isEmpty else { handoff.supply(nil); return }
        var sources: [(AudioTrack, ScopedFolder, VolumeAnalysisCandidate?)] = [], unavailable: [(String, String)] = []
        for track in candidates {
            do { let folder = try folderAccess(for: track); sources.append((track, folder, volumeCandidate(for: track, folder: folder, includeAlbum: listeningSettings.normalization == .album))) }
            catch { unavailable.append((track.id, error.localizedDescription)) }
        }
        let preparedSources = sources, sourceFailures = unavailable
        let token = generation, job = UUID(); lookAheadID = job
        let normalization = listeningSettings.normalization, balance = listeningSettings.balance, adaptive = transitionSettings.mode == .adaptive
        lookAhead = Task.detached(priority: .userInitiated) { [weak self] in
            var failures = sourceFailures
            for (track, folder, volume) in preparedSources {
                do {
                    let prepared = try await MediaReader.prepare(track, folder: folder, normalization: normalization, balance: balance, analyzeRhythm: adaptive, volume: volume)
                    try Task.checkCancellation()
                    handoff.supply(TransitionTrack.prepare(prepared, id: track.id))
                    await self?.transitionPrepared(after: id, token: token, job: job, failures: failures)
                    return
                } catch is CancellationError { return }
                catch { failures.append((track.id, "No se pudo abrir \(track.filename): \(error.localizedDescription)")) }
            }
            handoff.supply(nil)
            await self?.transitionPrepared(after: id, token: token, job: job, failures: failures)
        }
    }
    private func transitionPrepared(after id: ObjectIdentifier, token: UUID, job: UUID, failures: [(String, String)]) {
        guard generation == token, lookAheadID == job else { return }
        lookAhead = nil
        for (id, message) in failures { failedTracks.insert(id); issue = message }
        enqueueTransition(after: id)
        if let tail = transitionTail { prepareTransition(after: tail.id) }
        // Only finish an actual end-of-audio wait. During startup SFB can have
        // dequeued a source whose initialization has not yet made isReady true.
        if isPreparing && player.nowPlaying == nil && !player.isReady && player.queueIsEmpty && lookAhead == nil {
            isPreparing = false; playIntent = false; player.stop(); currentTime = duration; resumePosition = 0
            save(); updateNowPlaying()
        }
    }
    private func enqueueTransition(after id: ObjectIdentifier) {
        guard let entry = transitionEntry(id), entry.generation == generation, let handoff = entry.handoff,
              let (track, outcome) = handoff.takeForEnqueue() else { return }
        if case .failed(let message) = outcome {
            failedTracks.insert(track.id); issue = "No se pudo leer \(track.prepared.details.title): \(message)"
            handoff.retryAfterFailure(); prepareTransition(after: id)
            return
        }
        do { try submitTransition(track, outcome: outcome); isPreparing = false }
        catch { issue = error.localizedDescription; playIntent = false; updateNowPlaying() }
    }
    private func cache(_ value: TrackDetails, for id: String) {
        details[id] = value
        if let track = queue.tracks.first(where: { $0.id == id }), let source = track.sourceID ?? primaryLibraryID {
            library.update(value, source: source, track: track)
        }
        let protected = Set(entries.values.filter { $0.generation == generation }.map(\.trackID) + [current?.id, id].compactMap { $0 })
        for key in details.keys.sorted() where details.count > 16 && !protected.contains(key) { details.removeValue(forKey: key) }
    }
    private func refresh() {
        if case .deadline(let date) = sleepTimer, date <= Date() {
            storeSleepTimer(nil); pause(); return
        }
        if let decoder = player.nowPlaying,
           let entry = entries[ObjectIdentifier(decoder)], entry.generation == generation, entry.trackID == current?.id,
           let time = player.currentTime, time.isFinite {
            currentTime = max(0, time); resumePosition = currentTime
        }
        isPlaying = player.isPlaying && playIntent && !interrupted
        updateNowPlaying()
    }
    func interruptionBegan() { interrupted = true; refresh(); player.pause(); isPlaying = false; save(); updateNowPlaying() }
    func interruptionEnded(shouldResume: Bool) {
        interrupted = false
        if shouldResume && playIntent { resume() } else { playIntent = false }
    }
    private func updateNowPlaying() {
        guard let current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: currentDetails?.title ?? current.displayName,
            MPMediaItemPropertyArtist: currentDetails?.artist ?? "", MPMediaItemPropertyAlbumTitle: currentDetails?.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if let image = currentDetails?.artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private enum PlayerError: LocalizedError {
    case emptyFolder, noPlayableFiles
    var errorDescription: String? {
        switch self {
        case .emptyFolder: "Esta carpeta no contiene archivos de audio compatibles."
        case .noPlayableFiles: "No se pudo reproducir ningún archivo de esta carpeta."
        }
    }
}
