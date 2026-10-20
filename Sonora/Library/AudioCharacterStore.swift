import Foundation
import Observation
import SonoraCore

/// Jobs belong to the shared cache, not the current song or a presented sheet.
/// A successful refresh replaces saved data; a failure keeps the previous result.
@MainActor @Observable
final class AudioCharacterStore {
    enum Status: Equatable { case preparing, ready, waiting, failed(String) }
    typealias Analyzer = @MainActor (AudioTrack, ScopedFolder, FileFingerprint, Bool) async throws -> AudioCharacter
    private struct Binding: Codable, Sendable {
        let fingerprint: FileFingerprint
        let contentID: String
        let result: AudioCharacter
    }
    private var bindings: [String: Binding] = [:]
    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let cache: MusicToolsCache
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let analyzer: Analyzer?
    private struct Pending {
        let fingerprint: FileFingerprint
        let refresh: Bool
        let task: Task<AudioCharacter, Error>
    }
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var tail: Task<AudioCharacter, Error>?
    @ObservationIgnored private var tailID: UUID?
    @ObservationIgnored private var availability: Result<Void, Error>?

    init(settings: MetadataAssistantSettings = .shared, cache: MusicToolsCache = .shared, analyzer: Analyzer? = nil) {
        self.settings = settings; self.cache = cache; self.analyzer = analyzer
    }
    func key(_ track: AudioTrack, folder: ScopedFolder) -> String {
        "character-binding:\(AudioCharacter.version):" + track.url(in: folder.url).standardizedFileURL.absoluteString + ":" + track.localID
    }
    func summary(_ track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint) -> AudioCharacter? {
        let binding = bindings[key(track, folder: folder)]
        return binding?.fingerprint == expected ? binding?.result : nil
    }
    func status(_ track: AudioTrack, folder: ScopedFolder) -> Status? { statuses[key(track, folder: folder)] }
    func retry() { availability = nil; statuses = statuses.filter { $0.value == .preparing || $0.value == .ready } }

    func load(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint, preparedAudio: SongToolsResult? = nil,
              refresh: Bool = false, cachedOnly: Bool = false) async throws -> AudioCharacter {
        let key = key(track, folder: folder)
        if !refresh {
            if let result = summary(track, folder: folder, expected: expected) { return result }
            if let binding = try await cache.read(Binding.self, key: key), binding.fingerprint == expected, binding.result.isValid {
                bindings[key] = binding; statuses[key] = .ready; return binding.result
            }
        }
        if let job = pending[key] {
            if job.fingerprint == expected && (!refresh || job.refresh) { return try await job.task.value }
            _ = try? await job.task.value
            return try await load(track: track, folder: folder, expected: expected, preparedAudio: preparedAudio,
                                  refresh: refresh, cachedOnly: cachedOnly)
        }
        if refresh && (settings.effectiveOffline || settings.endpoint.isEmpty && analyzer == nil) {
            let error = AudioCharacterError.service("offline")
            statuses[key] = .failed(error.localizedDescription); throw error
        }
        let previous = tail, id = UUID()
        let job = Task { [self] () throws -> AudioCharacter in
            defer { pending[key] = nil; if tailID == id { tail = nil; tailID = nil } }
            _ = try? await previous?.value
            statuses[key] = .preparing
            do {
                let identity: String
                if let preparedAudio, preparedAudio.fingerprint == expected { identity = preparedAudio.contentID }
                else { identity = try await AudioContentIdentity.read(track: track, folder: folder, expected: expected) }
                let resultKey = "character:\(AudioCharacter.version):" + identity
                let result: AudioCharacter
                if !refresh, let saved = try await cache.read(AudioCharacter.self, key: resultKey), saved.isValid {
                    result = saved
                } else {
                    // Container URLs can change after an app update. Rebind an
                    // existing PCM result offline before considering any upload.
                    guard !cachedOnly, !settings.effectiveOffline, !settings.endpoint.isEmpty || analyzer != nil else {
                        statuses[key] = .waiting; throw MetadataLookupError.notCached
                    }
                    if let analyzer {
                        result = try await analyzer(track, folder, expected, refresh)
                    } else {
                        let client = AudioCharacterClient(connection: try MetadataProxyConnection(endpoint: settings.endpoint, token: settings.savedToken()))
                        if refresh { availability = nil }
                        if let availability { try availability.get() }
                        else {
                            do { try await client.checkAvailability(); availability = .success(()) }
                            catch { availability = .failure(error); throw error }
                        }
                        let audio = try await AudioCharacterPreparation.prepare(track: track, folder: folder, expected: expected)
                        result = try await client.analyze(audio, refresh: refresh)
                    }
                }
                guard result.isValid else { throw MetadataLookupError.invalidResponse }
                try await cache.write(result, key: resultKey)
                let binding = Binding(fingerprint: expected, contentID: identity, result: result)
                try await cache.write(binding, key: key)
                bindings[key] = binding; statuses[key] = .ready
                return result
            } catch {
                if case MetadataLookupError.notCached = error { statuses[key] = .waiting }
                else { statuses[key] = .failed(error.localizedDescription) }
                throw error
            }
        }
        pending[key] = Pending(fingerprint: expected, refresh: refresh, task: job); tail = job; tailID = id
        statuses[key] = .preparing
        return try await job.value
    }
}
