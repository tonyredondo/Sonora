import Foundation
import Observation
import SonoraCore

/// The player and sheets share bounded Codex capacity with translation. Leaving a sheet never
/// cancels a request that could already be consuming the user's plan.
@MainActor @Observable
final class LyricInterpretationStore {
    enum RequestMode: Equatable { case cachedOnly, useCache, refresh }
    typealias Interpreter = @MainActor (LyricsDocument, String, LyricsInterpretationContext, RequestMode) async throws -> LyricsInterpretation
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
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var workers = 0
    @ObservationIgnored private var issueRevision = 0
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private var ownerPriorities: [String: Int] = [:]
    @ObservationIgnored private var automaticLanguage: String?
    private struct Job {
        let document: LyricsDocument
        let language: String
        let context: LyricsInterpretationContext
        let endpoint: String
        var refresh = false
        var owners: Set<String> = []
        var waiters: [CheckedContinuation<LyricsInterpretation, Error>] = []
        var refreshWaiters: [CheckedContinuation<LyricsInterpretation, Error>] = []
    }

    init(settings: MetadataAssistantSettings = .shared, requests: CodexRequestPool = .shared, interpret: Interpreter? = nil) {
        self.settings = settings; self.requests = requests
        self.interpret = interpret ?? {
            try await LyricUnderstanding.interpret($0, language: $1, context: $2, cachedOnly: $3 == .cachedOnly,
                                                   refresh: $3 == .refresh, settings: settings)
        }
        observeConnection()
    }
    func key(_ document: LyricsDocument, language: String, context: LyricsInterpretationContext = .init()) -> String {
        // Same inputs as the existing disk cache; timing edits reuse meaning.
        LyricsInterpretationClient.version + ":" + settings.endpoint + ":" + language + ":" + context.cacheIdentity + ":" + MusicToolsCache.digest(document.lines.map(\.text).joined(separator: "\n"))
    }
    func restore(_ document: LyricsDocument, language: String, context: LyricsInterpretationContext = .init()) async {
        let key = key(document, language: language, context: context)
        guard results[key] == nil, let value = try? await interpret(document, language, context, .cachedOnly),
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
            if !active.contains(key), let job = jobs[key], job.owners.isEmpty && job.waiters.isEmpty {
                jobs[key] = nil; statuses[key] = results[key] == nil ? nil : .ready
            }
        }
        order.removeAll { jobs[$0] == nil }
        start()
    }
    func enqueue(_ document: LyricsDocument, language: String, context: LyricsInterpretationContext = .init(), owner: String) async {
        await restore(document, language: language, context: context)
        let key = key(document, language: language, context: context)
        guard ownerPriorities[owner] != nil, automaticLanguage == nil || automaticLanguage == language,
              results[key] == nil,
              document.lines.contains(where: { !$0.text.isEmpty }) else { return }
        if case .failed = statuses[key] { return } // Explicit retry or connection recovery, never a skip-triggered retry storm.
        if jobs[key] == nil {
            jobs[key] = Job(document: document, language: language, context: context, endpoint: settings.endpoint)
            order.append(key); statuses[key] = .queued
        }
        jobs[key]?.owners.insert(owner)
        start()
    }
    func load(_ document: LyricsDocument, language: String, context: LyricsInterpretationContext = .init(), refresh: Bool = false) async throws -> LyricsInterpretation {
        if !refresh { await restore(document, language: language, context: context) }
        try Task.checkCancellation()
        let key = key(document, language: language, context: context)
        if !refresh, let value = results[key] { return value }
        let value: LyricsInterpretation = try await withCheckedThrowingContinuation { continuation in
            if jobs[key] == nil {
                jobs[key] = Job(document: document, language: language, context: context, endpoint: settings.endpoint, refresh: refresh)
                order.append(key); statuses[key] = .queued
            }
            if refresh && active.contains(key) && jobs[key]?.refresh == false {
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
        issueRevision += 1
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                retryAutomatic()
                observeConnection()
            }
        }
    }
    private func next() -> String? {
        // Explicit requests take priority, then the current playback order.
        let candidates = order.filter { jobs[$0] != nil && !active.contains($0) }
        if let manual = candidates.first(where: { jobs[$0]?.waiters.isEmpty == false }) { return manual }
        guard automaticIssue == nil, !waitingForConnection else { return nil }
        return candidates.compactMap { key -> (key: String, priority: Int)? in
            guard let rank = jobs[key]?.owners.compactMap({ ownerPriorities[$0] }).min() else { return nil }
            return (key, rank)
        }.min { $0.priority < $1.priority }?.key
    }
    private func start() {
        while workers < CodexRequestPool.capacity, next() != nil {
            workers += 1
            Task(priority: .utility) { [self] in
                defer { workers -= 1 }
                while next() != nil {
                    await requests.perform {
                        guard let key = next(), let job = jobs[key] else { return }
                        await run(key, job: job)
                    }
                }
            }
        }
    }
    private func run(_ key: String, job: Job) async {
        active.insert(key)
        statuses[key] = .interpreting
        let connectionRevision = settings.configurationRevision
        let startedIssueRevision = issueRevision
        var retryWhenConnected = false
        let result: Result<LyricsInterpretation, Error>
        do {
            guard job.endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
            let value = try await interpret(job.document, job.language, job.context, job.refresh ? .refresh : .useCache)
            guard value.isValid else { throw MetadataLookupError.invalidResponse }
            results[key] = value; statuses[key] = .ready
            // Another in-flight request may have reported a newer outage.
            if issueRevision == startedIssueRevision { automaticIssue = nil }
            result = .success(value)
        } catch {
            statuses[key] = .failed(error.localizedDescription)
            // A disconnected server or exhausted plan affects the whole
            // remote queue, but must not block local audio or translation.
            if job.endpoint == settings.endpoint, connectionRevision == settings.configurationRevision,
               Self.blocksAutomaticQueue(error) {
                issueRevision += 1
                automaticIssue = error.localizedDescription
                retryWhenConnected = true
            }
            result = .failure(error)
        }
        let waiters = jobs[key]?.waiters ?? []
        if let refreshWaiters = jobs[key]?.refreshWaiters, !refreshWaiters.isEmpty {
            jobs[key] = Job(document: job.document, language: job.language, context: job.context, endpoint: job.endpoint,
                            refresh: true, waiters: refreshWaiters)
            statuses[key] = .queued
        } else if retryWhenConnected, !job.refresh, jobs[key]?.owners.isEmpty == false {
            // Retain a failed automatic request for reconnect/retry,
            // without leaving explicit callers waiting indefinitely.
            jobs[key]?.waiters = []
        } else {
            jobs[key] = nil
            order.removeAll { $0 == key }
        }
        active.remove(key)
        for waiter in waiters { waiter.resume(with: result) }
    }
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case LyricsInterpretationError.service(let code, _) = error { return code != "codex_invalid_response" }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }
}
