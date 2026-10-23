import Foundation
import Observation
import SonoraCore

/// An immutable library snapshot; the queue chooses albums, never their membership.
struct AlbumPreparationRequest {
    let id: String
    let title: String
    let artist: String
    let songs: [CollectionSong]
    let revision: String
    init(group: CollectionGroup, songs: [CollectionSong]) {
        self.init(id: group.id, title: group.title, artist: group.subtitle, songs: songs)
    }
    /// Metadata context for reading a saved album interpretation from one file.
    init(document: CollectionSong) {
        self.init(id: document.albumID, title: document.album, artist: document.albumArtist, songs: [document])
    }
    private init(id: String, title: String, artist: String, songs: [CollectionSong]) {
        self.id = id; self.title = title; self.artist = artist; self.songs = songs
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        struct SongRevision: Encodable {
            let id: String
            let tags: [String: String]
            let cueStart: Int?
            let cueEnd: Int?
            let modified: Date?
        }
        // Playback and indexing format descriptions can differ. Only album
        // membership, source content and metadata invalidate the corpus.
        let content = songs.map { SongRevision(id: $0.id, tags: Dictionary(uniqueKeysWithValues: $0.tags.map { ($0.key.rawValue, $0.value) }),
                                                cueStart: $0.cue?.startCDFrame, cueEnd: $0.cue?.endCDFrame, modified: $0.modified) }
        revision = MusicToolsCache.digest(String(decoding: try! encoder.encode(content), as: UTF8.self))
    }
}

@MainActor @Observable
final class AlbumInterpretationStore {
    // Collected source text stays reusable when only the interpretation is reset.
    private static let corpusVersion = "codex-album-v1"
    struct Prepared: Codable, Sendable {
        let album: AlbumInterpretationInput?
        let interpretation: LyricsInterpretation
        let embedded: PortableInterpretations.Album?
        init(album: AlbumInterpretationInput, interpretation: LyricsInterpretation) {
            self.album = album; self.interpretation = interpretation; embedded = nil
        }
        init(embedded: PortableInterpretations.Album) {
            album = nil; interpretation = embedded.interpretation; self.embedded = embedded
        }
        var isValid: Bool {
            guard interpretation.isValid else { return false }
            if let album { return embedded == nil && album.isValid }
            return embedded?.isValid == true && embedded?.interpretation == interpretation
        }
        var title: String { album?.title ?? embedded?.title ?? "" }
        var trackCount: Int { album?.tracks.count ?? embedded?.trackCount ?? 0 }
        var missingLyrics: Int { album?.missingLyrics ?? embedded?.missingLyrics ?? 0 }
    }
    enum Status: Equatable {
        case queued, collecting, interpreting, ready, waiting, failed(String)
        var busy: Bool { self == .queued || self == .collecting || self == .interpreting }
    }
    typealias Collector = @MainActor (AlbumPreparationRequest, Bool) async throws -> AlbumInterpretationInput
    typealias Interpreter = @MainActor (AlbumInterpretationInput, String, Bool) async throws -> LyricsInterpretation
    @ObservationIgnored var readEmbedded: (@MainActor (AlbumPreparationRequest, String) async -> PortableInterpretations.Album?)?
    private(set) var results: [String: Prepared] = [:]
    private(set) var statuses: [String: Status] = [:]
    private(set) var automaticIssue: String?
    var waitingForConnection: Bool { settings.effectiveOffline || settings.endpoint.isEmpty }
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let cache: MusicToolsCache
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private let interpret: Interpreter
    @ObservationIgnored private var collect: Collector?
    @ObservationIgnored private var desired: [AlbumPreparationRequest] = []
    @ObservationIgnored private var preferences: QueuePreparationPreferences?
    @ObservationIgnored private var pending: [String: (refresh: Bool, task: Task<Prepared, Error>)] = [:]
    @ObservationIgnored private var collectionTail: Task<AlbumInterpretationInput, Error>?
    @ObservationIgnored private var collectionID: UUID?

    init(settings: MetadataAssistantSettings = .shared, cache: MusicToolsCache = .shared,
         requests: CodexRequestPool = .shared, interpret: Interpreter? = nil) {
        self.settings = settings; self.cache = cache; self.requests = requests
        self.interpret = interpret ?? { album, language, refresh in
            let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: settings.savedToken())
            return try await AlbumInterpretationClient(connection: connection, cache: settings.cache)
                .interpret(album, language: language, offline: settings.effectiveOffline, refresh: refresh)
        }
        observeConnection()
    }
    func key(_ album: AlbumPreparationRequest, language: String, character: Bool) -> String {
        "\(AlbumInterpretationClient.version):\(settings.endpoint):\(language):\(AudioCharacter.version):\(character):\(album.id):\(album.revision)"
    }
    func update(_ albums: [AlbumPreparationRequest], preferences: QueuePreparationPreferences, collect: @escaping Collector) {
        if self.preferences != preferences {
            statuses = statuses.filter { $0.value.busy || $0.value == .ready }
        }
        desired = albums; self.collect = collect; self.preferences = preferences
        start()
    }
    func retry() {
        statuses = statuses.filter { $0.value.busy || $0.value == .ready }
        automaticIssue = nil
        start()
    }
    private func observeConnection() {
        withObservationTracking {
            _ = settings.effectiveOffline; _ = settings.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.retry(); self?.observeConnection() }
        }
    }
    private func start() {
        guard let preferences, let collect else { return }
        for album in desired {
            guard Set(pending.keys).union(statuses.filter { $0.value == .queued }.keys).count < CodexRequestPool.capacity else { break }
            let key = key(album, language: preferences.meaningLanguage, character: preferences.character)
            guard pending[key] == nil, statuses[key] == nil else { continue }
            statuses[key] = .queued
            Task { [self] in
                _ = try? await load(album, language: preferences.meaningLanguage, character: preferences.character,
                                    cachedOnly: !preferences.meaning || waitingForConnection || automaticIssue != nil, collect: collect)
                start()
            }
            // The queued status reserves capacity before this task starts.
        }
    }
    /// A completed result or an embedded reading, without joining or starting remote work.
    func cachedResult(_ album: AlbumPreparationRequest, language: String, character: Bool) async throws -> Prepared? {
        let key = key(album, language: language, character: character)
        if let result = results[key] { return result }
        let result: Prepared
        if let cached = try await cache.read(Prepared.self, key: key), cached.isValid { result = cached }
        else if let saved = await readEmbedded?(album, language), saved.isValid {
            result = Prepared(embedded: saved)
            try await cache.write(result, key: key)
        } else { return nil }
        // A refresh may have finished while the file/cache read was suspended.
        if let newer = results[key] { return newer }
        results[key] = result; statuses[key] = .ready
        return result
    }

    /// Refresh waits for an older request, then coalesces into one explicit regeneration.
    /// Active work finishes into its own revision even if the playing album changes.
    func load(_ album: AlbumPreparationRequest, language: String, character: Bool, refresh: Bool = false,
              cachedOnly: Bool = false, collect: @escaping Collector) async throws -> Prepared {
        let key = key(album, language: language, character: character)
        if !refresh, let result = results[key] { statuses[key] = .ready; return result }
        if let job = pending[key] {
            if refresh && !job.refresh {
                _ = try? await job.task.value
                return try await load(album, language: language, character: character, refresh: true, collect: collect)
            }
            return try await job.task.value
        }
        let endpoint = settings.endpoint, connectionRevision = settings.configurationRevision
        let task = Task { [self] () throws -> Prepared in
            defer { pending[key] = nil; start() }
            do {
                if !refresh, let saved = try await cachedResult(album, language: language, character: character) { return saved }
                guard !cachedOnly, !waitingForConnection else { throw MetadataLookupError.notCached }
                statuses[key] = .collecting
                let corpusKey = "album-corpus:\(Self.corpusVersion):\(AudioCharacter.version):\(character):\(album.id):\(album.revision)"
                let corpus: AlbumInterpretationInput
                if !refresh, let saved = try await cache.read(AlbumInterpretationInput.self, key: corpusKey), saved.isValid { corpus = saved }
                else {
                    let previous = collectionTail, id = UUID()
                    let task = Task { _ = try? await previous?.value; return try await collect(album, character) }
                    collectionTail = task; collectionID = id
                    defer { if collectionID == id { collectionTail = nil; collectionID = nil } }
                    corpus = try await task.value
                    guard corpus.isValid else {
                        throw MusicTextError.invalid(corpus.missingLyrics == corpus.tracks.count
                            ? "Este álbum todavía no tiene letras disponibles para analizar."
                            : "El álbum supera el límite de análisis (100 canciones o 256 KB de letra). No se ha recortado su contenido.")
                    }
                    try await cache.write(corpus, key: corpusKey)
                }
                var response: Result<LyricsInterpretation, Error>?
                await requests.perform {
                    do {
                        guard endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
                        statuses[key] = .interpreting
                        response = .success(try await interpret(corpus, language, refresh))
                    } catch { response = .failure(error) }
                }
                guard let response else { throw MetadataLookupError.invalidResponse }
                let result = Prepared(album: corpus, interpretation: try response.get())
                guard result.interpretation.isValid else { throw MetadataLookupError.invalidResponse }
                try await cache.write(result, key: key)
                results[key] = result; statuses[key] = .ready
                return result
            } catch {
                if case MetadataLookupError.notCached = error { statuses[key] = .waiting }
                else {
                    statuses[key] = .failed(error.localizedDescription)
                    if endpoint == settings.endpoint, connectionRevision == settings.configurationRevision,
                       Self.blocksAutomaticQueue(error) { automaticIssue = error.localizedDescription }
                }
                throw error
            }
        }
        pending[key] = (refresh, task)
        return try await task.value
    }
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if error is URLError || error is MetadataTransportFailure || error is LyricsInterpretationError { return true }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }

}
