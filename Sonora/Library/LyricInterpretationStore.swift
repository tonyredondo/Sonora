import Foundation
import Observation
import SonoraCore

/// The player and sheets share one serial Codex worker. Leaving a sheet never
/// cancels a request that could already be consuming the user's plan.
@MainActor @Observable
final class LyricInterpretationStore {
    enum RequestMode: Equatable { case cachedOnly, useCache, refresh }
    typealias Interpreter = @MainActor (LyricsDocument, String, RequestMode) async throws -> LyricsInterpretation
    enum Status: Equatable {
        case queued, interpreting, ready, failed(String)
        var busy: Bool { self == .queued || self == .interpreting }
    }
    private(set) var results: [String: LyricsInterpretation] = [:]
    private(set) var statuses: [String: Status] = [:]
    private(set) var automaticIssue: String?
    var waitingForConnection: Bool { settings.effectiveOffline || settings.endpoint.isEmpty }
    var pendingCount: Int { statuses.filter { $0.value.busy || jobs[$0.key] != nil }.count }
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let interpret: Interpreter
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var active: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var ownerPriorities: [String: Int] = [:]
    @ObservationIgnored private var automaticLanguage: String?
    private struct Job {
        let document: LyricsDocument
        let language: String
        let endpoint: String
        var refresh = false
        var owners: Set<String> = []
        var waiters: [CheckedContinuation<LyricsInterpretation, Error>] = []
        var refreshWaiters: [CheckedContinuation<LyricsInterpretation, Error>] = []
    }

    init(settings: MetadataAssistantSettings = .shared, interpret: Interpreter? = nil) {
        self.settings = settings
        self.interpret = interpret ?? {
            try await LyricUnderstanding.interpret($0, language: $1, cachedOnly: $2 == .cachedOnly,
                                                   refresh: $2 == .refresh, settings: settings)
        }
        observeConnection()
    }
    func key(_ document: LyricsDocument, language: String) -> String {
        // Same inputs as the existing disk cache; timing edits reuse meaning.
        settings.endpoint + ":" + language + ":" + MusicToolsCache.digest(document.lines.map(\.text).joined(separator: "\n"))
    }
    func restore(_ document: LyricsDocument, language: String) async {
        let key = key(document, language: language)
        guard results[key] == nil, let value = try? await interpret(document, language, .cachedOnly),
              value.isValid, results[key] == nil else { return }
        results[key] = value
        if jobs[key] == nil { statuses[key] = .ready }
    }
    func setAutomaticQueue(_ owners: [String], language: String? = nil) {
        ownerPriorities = Dictionary(owners.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        automaticLanguage = language
        let allowed = Set(ownerPriorities.keys)
        for key in order {
            jobs[key]?.owners.formIntersection(allowed)
            if let job = jobs[key], (language != nil && job.language != language) || job.endpoint != settings.endpoint {
                jobs[key]?.owners = []
            }
            if key != active, let job = jobs[key], job.owners.isEmpty && job.waiters.isEmpty {
                jobs[key] = nil; statuses[key] = results[key] == nil ? nil : .ready
            }
        }
        order.removeAll { jobs[$0] == nil }
        start()
    }
    func enqueue(_ document: LyricsDocument, language: String, owner: String) async {
        await restore(document, language: language)
        let key = key(document, language: language)
        guard ownerPriorities[owner] != nil, automaticLanguage == nil || automaticLanguage == language,
              results[key] == nil,
              document.lines.contains(where: { !$0.text.isEmpty }) else { return }
        if case .failed = statuses[key] { return } // Explicit retry or connection recovery, never a skip-triggered retry storm.
        if jobs[key] == nil {
            jobs[key] = Job(document: document, language: language, endpoint: settings.endpoint)
            order.append(key); statuses[key] = .queued
        }
        jobs[key]?.owners.insert(owner)
        start()
    }
    func load(_ document: LyricsDocument, language: String, refresh: Bool = false) async throws -> LyricsInterpretation {
        if !refresh { await restore(document, language: language) }
        try Task.checkCancellation()
        let key = key(document, language: language)
        if !refresh, let value = results[key] { return value }
        let value: LyricsInterpretation = try await withCheckedThrowingContinuation { continuation in
            if jobs[key] == nil {
                jobs[key] = Job(document: document, language: language, endpoint: settings.endpoint, refresh: refresh)
                order.append(key); statuses[key] = .queued
            }
            if refresh && active == key && jobs[key]?.refresh == false {
                // The active cache-using call cannot be promoted after it starts.
                // Coalesce all explicit refreshes into one following request.
                jobs[key]?.refreshWaiters.append(continuation)
            } else {
                if refresh { jobs[key]?.refresh = true }
                jobs[key]?.waiters.append(continuation)
            }
            start()
        }
        try Task.checkCancellation()
        return value
    }
    func retryAutomatic() {
        automaticIssue = nil
        for (key, status) in statuses {
            if case .failed = status { statuses[key] = jobs[key] == nil ? nil : .queued }
        }
        start()
    }
    private func observeConnection() {
        withObservationTracking {
            _ = settings.effectiveOffline
            _ = settings.configurationRevision
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                retryAutomatic()
                observeConnection()
            }
        }
    }
    private func next() -> String? {
        // Explicit requests take priority, then the current playback order.
        let candidates = order.filter { jobs[$0] != nil }
        if let manual = candidates.first(where: { jobs[$0]?.waiters.isEmpty == false }) { return manual }
        guard automaticIssue == nil, !waitingForConnection else { return nil }
        return candidates.compactMap { key -> (key: String, priority: Int)? in
            guard let rank = jobs[key]?.owners.compactMap({ ownerPriorities[$0] }).min() else { return nil }
            return (key, rank)
        }.min { $0.priority < $1.priority }?.key
    }
    private func start() {
        guard worker == nil, next() != nil else { return }
        worker = Task(priority: .utility) { [self] in
            defer { active = nil; worker = nil }
            while let key = next(), let job = jobs[key] {
                active = key
                statuses[key] = .interpreting
                let connectionRevision = settings.configurationRevision
                let result: Result<LyricsInterpretation, Error>
                do {
                    guard job.endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
                    let value = try await interpret(job.document, job.language, job.refresh ? .refresh : .useCache)
                    guard value.isValid else { throw MetadataLookupError.invalidResponse }
                    results[key] = value; statuses[key] = .ready
                    automaticIssue = nil
                    result = .success(value)
                } catch {
                    statuses[key] = .failed(error.localizedDescription)
                    // A disconnected server or exhausted plan affects the whole
                    // remote queue, but must not block local audio or translation.
                    if job.endpoint == settings.endpoint, connectionRevision == settings.configurationRevision,
                       Self.blocksAutomaticQueue(error) { automaticIssue = error.localizedDescription }
                    result = .failure(error)
                }
                let waiters = jobs[key]?.waiters ?? []
                if let refreshWaiters = jobs[key]?.refreshWaiters, !refreshWaiters.isEmpty {
                    jobs[key] = Job(document: job.document, language: job.language, endpoint: job.endpoint,
                                    refresh: true, waiters: refreshWaiters)
                    statuses[key] = .queued
                } else if automaticIssue != nil, !job.refresh, jobs[key]?.owners.isEmpty == false {
                    // Retain a failed automatic request for reconnect/retry,
                    // without leaving explicit callers waiting indefinitely.
                    jobs[key]?.waiters = []
                } else {
                    jobs[key] = nil
                    order.removeAll { $0 == key }
                }
                active = nil
                for waiter in waiters { waiter.resume(with: result) }
            }
        }
    }
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case LyricsInterpretationError.service(let code, _) = error { return code != "codex_invalid_response" }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }
}
